// DOM helpers. Everything that touches `document` goes through here, so the
// rest of the code deals in elements it already knows exist.

/** An element by id, or `null`. */
export function el<T extends HTMLElement = HTMLElement>(id: string): T | null {
  return document.getElementById(id) as T | null;
}

/**
 * An element the markup guarantees, throwing if it is missing.
 *
 * The old code read `.value` off whatever `getElementById` returned, so a typo in
 * an id — or an element that had not been rendered yet — was a silent
 * `undefined` that surfaced later as a wrong value. Throwing here turns that into
 * a named failure at the point of use.
 */
export function must<T extends HTMLElement = HTMLElement>(id: string): T {
  const node = el<T>(id);
  if (!node) {
    throw new Error(`#${id} is not in the document`);
  }
  return node;
}

/** Escape for interpolation into an HTML string. */
export function esc(value: unknown): string {
  return String(value ?? "").replace(/[&<>"']/g, (character) => {
    switch (character) {
      case "&":
        return "&amp;";
      case "<":
        return "&lt;";
      case ">":
        return "&gt;";
      case '"':
        return "&quot;";
      default:
        return "&#39;";
    }
  });
}

let toastTimer: number | undefined;

/** A transient message at the foot of the window. */
export function toast(message: string): void {
  const node = el("toast");
  if (!node) return;
  node.textContent = message;
  node.classList.add("show");
  clearTimeout(toastTimer);
  toastTimer = window.setTimeout(() => node.classList.remove("show"), 1800);
}

/**
 * Attaches a listener that reports its own failure.
 *
 * A handler that throws used to fail into the void: the trend chart's tooltip
 * referenced a variable that was not in scope and threw on every mousemove, and
 * nothing anywhere said so — the tooltip simply never appeared. Routing every
 * handler through here makes that visible.
 */
export function on<E extends Event = Event>(
  node: EventTarget | null,
  event: string,
  handler: (event: E) => void | Promise<void>
): void {
  // Every pane's `wire` runs on every render, so an element belonging to another
  // pane is legitimately absent. Callers that require their own markup check for
  // it first and then use `must`, which is where a typo becomes loud.
  if (!node) return;
  node.addEventListener(event, (raw) => {
    try {
      const result = handler(raw as E);
      if (result instanceof Promise) {
        result.catch((error: unknown) => toast(String(error)));
      }
    } catch (error) {
      toast(String(error));
    }
  });
}

/** Attaches to every element matching `selector` inside `root`. */
export function onAll<E extends Event = Event>(
  root: ParentNode,
  selector: string,
  event: string,
  handler: (event: E) => void | Promise<void>
): void {
  for (const node of root.querySelectorAll(selector)) {
    on<E>(node, event, handler);
  }
}

/**
 * Splits a `provider|window` key.
 *
 * `lastIndexOf`, because a window label may itself contain the separator — the
 * old `indexOf` would have split in the wrong place.
 */
export function splitKey(key: string): [string, string] {
  const index = key.lastIndexOf("|");
  return [key.slice(0, index), key.slice(index + 1)];
}

/** The dataset of the element a handler fired on. */
export function targetData(event: Event): DOMStringMap {
  const target = event.currentTarget;
  if (!(target instanceof HTMLElement)) {
    throw new Error("handler fired without an element target");
  }
  return target.dataset;
}

/** The value of a handler's target, for inputs and selects. */
export function targetValue(event: Event): string {
  const target = event.currentTarget;
  if (!(target instanceof HTMLInputElement || target instanceof HTMLSelectElement)) {
    throw new Error("handler fired without a value-bearing target");
  }
  return target.value;
}

/** Whether a checkbox handler's target is checked. */
export function targetChecked(event: Event): boolean {
  const target = event.currentTarget;
  if (!(target instanceof HTMLInputElement)) {
    throw new Error("handler fired without an input target");
  }
  return target.checked;
}
