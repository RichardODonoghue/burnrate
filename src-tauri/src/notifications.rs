//! Native notifications.
//!
//! On macOS this posts through `UNUserNotificationCenter`. The Tauri notification
//! plugin cannot be used for that: it routes through `notify-rust` →
//! `mac-notification-sys`, which builds an `NSUserNotification` and hands it to
//! `NSUserNotificationCenter` — the API deprecated in macOS 10.14 and inert on
//! current releases. Its `show()` also spawns the delivery and discards the
//! result, so it returns `Ok(())` while nothing is ever displayed. That is what
//! "notifications do not work" looked like: every log line said accepted.
//!
//! The Swift build used `UNUserNotificationCenter`, which is why its banners
//! worked, and this is the same framework through `objc2`.
//!
//! Every call here blocks on the completion handler with a timeout, because the
//! whole point is to be able to report what the system actually did.
//!
//! This module is macOS-only; `lib.rs` keeps the plugin's path for the other
//! platforms, where it works.

#[cfg(target_os = "macos")]
pub use macos::{authorise, permission_state, post};

#[cfg(target_os = "macos")]
mod macos {
    use block2::RcBlock;
    use objc2::rc::Retained;
    use objc2::runtime::{Bool, ProtocolObject};
    use objc2::{define_class, msg_send, AllocAnyThread};
    use objc2_foundation::{NSBundle, NSError, NSObject, NSObjectProtocol, NSString};
    use objc2_user_notifications::{
        UNAuthorizationOptions, UNAuthorizationStatus, UNMutableNotificationContent,
        UNNotification, UNNotificationPresentationOptions, UNNotificationRequest,
        UNNotificationSettings, UNUserNotificationCenter, UNUserNotificationCenterDelegate,
    };
    use std::ptr::NonNull;
    use std::sync::mpsc;
    use std::sync::OnceLock;
    use std::time::Duration;

    /// Long enough for the permission prompt's own round trip, short enough that
    /// a wedged notification daemon cannot stall the poll loop.
    const ANSWER_TIMEOUT: Duration = Duration::from_secs(10);

    // Asks the centre to show a banner even when BurnRate is the frontmost app.
    //
    // Without a delegate macOS drops a notification that arrives while the app is
    // frontmost: no banner, no sound, nothing but an entry in Notification Center.
    // That is the whole difference between the welcome banner, which fires three
    // seconds after launch before the window takes focus, and the test button,
    // which is pressed *in* the window.
    define_class!(
        // SAFETY: NSObject has no subclassing requirements and this class holds no
        // ivars.
        #[unsafe(super(NSObject))]
        #[name = "BurnRateNotificationPresenter"]
        #[ivars = ()]
        struct ForegroundPresenter;

        unsafe impl NSObjectProtocol for ForegroundPresenter {}

        unsafe impl UNUserNotificationCenterDelegate for ForegroundPresenter {
            #[unsafe(method(userNotificationCenter:willPresentNotification:withCompletionHandler:))]
            fn will_present(
                &self,
                _center: &UNUserNotificationCenter,
                _notification: &UNNotification,
                completion_handler: &block2::DynBlock<dyn Fn(UNNotificationPresentationOptions)>,
            ) {
                completion_handler.call((UNNotificationPresentationOptions::Banner
                    | UNNotificationPresentationOptions::Sound,));
            }
        }
    );

    impl ForegroundPresenter {
        fn new() -> Retained<Self> {
            let this = Self::alloc().set_ivars(());
            // SAFETY: NSObject's init has no preconditions.
            unsafe { msg_send![super(this), init] }
        }
    }

    /// The centre holds a weak reference to its delegate, so the instance has to
    /// be kept alive for the process's lifetime.
    static PRESENTER: OnceLock<Retained<ForegroundPresenter>> = OnceLock::new();

    /// Installs the presenter once. Idempotent, because every entry point calls it.
    fn install_presenter(center: &UNUserNotificationCenter) {
        let presenter = PRESENTER.get_or_init(ForegroundPresenter::new);
        center.setDelegate(Some(ProtocolObject::from_ref(&**presenter)));
        // Announced once: a delegate that did not take looks exactly like one
        // that is never asked, and both are a blank screen with no error.
        static ANNOUNCED: std::sync::Once = std::sync::Once::new();
        ANNOUNCED.call_once(|| {
            eprintln!(
                "burnrate: notification delegate installed: {}, responds to willPresent: {}",
                center.delegate().is_some(),
                presenter.respondsToSelector(objc2::sel!(
                    userNotificationCenter:willPresentNotification:withCompletionHandler:
                ))
            );
        });
    }

    /// The notification centre, or `None` when this process has no bundle.
    ///
    /// `UNUserNotificationCenter.current()` raises an Objective-C exception
    /// without a bundle identifier, and an ObjC exception in Rust is an abort —
    /// so the check has to come first. `tauri dev` runs the bare binary, which is
    /// exactly that case.
    fn center() -> Option<objc2::rc::Retained<UNUserNotificationCenter>> {
        NSBundle::mainBundle().bundleIdentifier().map(|_| {
            let center = UNUserNotificationCenter::currentNotificationCenter();
            install_presenter(&center);
            center
        })
    }

    fn describe(status: UNAuthorizationStatus) -> String {
        if status == UNAuthorizationStatus::Authorized {
            "authorized".to_string()
        } else if status == UNAuthorizationStatus::Denied {
            "denied".to_string()
        } else if status == UNAuthorizationStatus::Provisional {
            "provisional".to_string()
        } else if status == UNAuthorizationStatus::Ephemeral {
            "ephemeral".to_string()
        } else {
            "not determined".to_string()
        }
    }

    /// Asks for permission, prompting on first run. Returns what was decided.
    pub fn authorise() -> String {
        let Some(center) = center() else {
            return "unavailable: no app bundle (a built app, not `tauri dev`)".to_string();
        };
        let (sender, receiver) = mpsc::channel();
        let handler = RcBlock::new(move |granted: Bool, error: *mut NSError| {
            // SAFETY: the framework passes either null or a live NSError.
            let message =
                unsafe { error.as_ref() }.map(|error| error.localizedDescription().to_string());
            let _ = sender.send((granted.as_bool(), message));
        });
        center.requestAuthorizationWithOptions_completionHandler(
            UNAuthorizationOptions::Alert | UNAuthorizationOptions::Sound,
            &handler,
        );
        match receiver.recv_timeout(ANSWER_TIMEOUT) {
            Ok((true, _)) => "granted".to_string(),
            Ok((false, Some(error))) => format!("denied ({error})"),
            Ok((false, None)) => "denied".to_string(),
            Err(_) => "no answer from the notification centre".to_string(),
        }
    }

    /// The current setting, without prompting.
    pub fn permission_state() -> String {
        let Some(center) = center() else {
            return "unavailable: no app bundle (a built app, not `tauri dev`)".to_string();
        };
        let (sender, receiver) = mpsc::channel();
        let handler = RcBlock::new(move |settings: NonNull<UNNotificationSettings>| {
            // SAFETY: the framework hands over a live settings object.
            let status = unsafe { settings.as_ref() }.authorizationStatus();
            let _ = sender.send(status);
        });
        center.getNotificationSettingsWithCompletionHandler(&handler);
        match receiver.recv_timeout(ANSWER_TIMEOUT) {
            Ok(status) => describe(status),
            Err(_) => "unknown (no answer)".to_string(),
        }
    }

    /// Posts a banner. Blocks until the system reports the request accepted.
    pub fn post(title: &str, body: &str) -> Result<(), String> {
        let Some(center) = center() else {
            return Err(
                "no app bundle, so notifications only work from a built app, not `tauri dev`"
                    .to_string(),
            );
        };
        let content = UNMutableNotificationContent::new();
        content.setTitle(&NSString::from_str(title));
        content.setBody(&NSString::from_str(body));
        // A nil trigger delivers immediately. The identifier has to be unique per
        // request or the system replaces the previous banner instead of stacking.
        let identifier = NSString::from_str(&format!(
            "burnrate-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|elapsed| elapsed.as_millis())
                .unwrap_or(0)
        ));
        let request = UNNotificationRequest::requestWithIdentifier_content_trigger(
            &identifier,
            &content,
            None,
        );
        let (sender, receiver) = mpsc::channel();
        let handler = RcBlock::new(move |error: *mut NSError| {
            // SAFETY: the framework passes either null or a live NSError.
            let message =
                unsafe { error.as_ref() }.map(|error| error.localizedDescription().to_string());
            let _ = sender.send(message);
        });
        center.addNotificationRequest_withCompletionHandler(&request, Some(&handler));
        match receiver.recv_timeout(ANSWER_TIMEOUT) {
            Ok(None) => Ok(()),
            Ok(Some(error)) => Err(error),
            Err(_) => Err("no answer from the notification centre".to_string()),
        }
    }
}
