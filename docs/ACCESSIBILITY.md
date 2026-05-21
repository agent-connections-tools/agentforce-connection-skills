# Accessibility Guide — Portal Response Formats

WCAG 2.1 AA compliance requirements for the in-app portal chat and format renderers.

---

## Chat Surface

| Requirement | Implementation | WCAG Criterion |
|-------------|---------------|----------------|
| Message input is keyboard-accessible | `<textarea>` with Enter to send, Shift+Enter for newline | 2.1.1 Keyboard |
| Send button has accessible label | `aria-label="Send message"` | 1.1.1 Non-text Content |
| New messages are announced | Container has `role="log"` + `aria-live="polite"` | 4.1.3 Status Messages |
| Loading state is announced | Loading indicator has `aria-label="Agent is thinking"` | 4.1.3 Status Messages |
| Error messages are announced | Error container has `role="alert"` | 4.1.3 Status Messages |
| Focus returns to input after send | `inputRef.focus()` called after response arrives | 2.4.3 Focus Order |

---

## InAppCard

| Requirement | Implementation |
|-------------|---------------|
| Card is a landmark | `role="article"` with `aria-label={title}` |
| Image is decorative | `alt=""` (content is in title/body text) |
| Buttons are keyboard-accessible | Standard `<button>` elements |
| Button purpose is clear | `aria-label={label}` on each button |

---

## InAppList

| Requirement | Implementation |
|-------------|---------------|
| List semantics | `role="list"` on container, `role="listitem"` on each item |
| Clickable items are focusable | `tabIndex={0}` on items with actions |
| Keyboard activation | `onKeyDown` handler responds to Enter |
| Item purpose is clear | `aria-label={title}` on each item |
| Icon is decorative | `alt=""` on icon images |

---

## InAppButtonGroup

| Requirement | Implementation |
|-------------|---------------|
| Group semantics | `role="group"` with `aria-label="Action choices"` |
| Buttons are standard | `<button>` elements (not divs/spans) |
| Button labels are descriptive | `aria-label={label}` |
| Focus visible | `:focus-visible` outline style (2px solid #0066ff) |

---

## InAppForm

| Requirement | Implementation |
|-------------|---------------|
| Labels associated with inputs | `<label htmlFor={fieldId}>` or `<lightning-input label={...}>` |
| Required fields indicated | Visual `*` + `aria-label="required"` on the asterisk |
| Validation errors announced | Error `<span>` has `role="alert"` |
| Invalid state communicated | `aria-invalid="true"` on failing inputs |
| Form has accessible name | `aria-label={title}` on `<form>` |
| Submit via keyboard | Standard form submission with Enter key |

---

## InAppCarousel

| Requirement | Implementation |
|-------------|---------------|
| Carousel has accessible name | `aria-label={title}` |
| Cards are list items | `role="list"` on track, `role="listitem"` on each card |
| Navigation buttons labeled | `aria-label="Scroll left"` / `aria-label="Scroll right"` |
| Cards are not keyboard-trapped | Tab moves through cards naturally |
| Images are decorative | `alt=""` (content is in title/description) |
| Badge text is accessible | Badge is visible text (no aria-hidden) |

---

## Color Contrast

All text meets WCAG AA minimum contrast ratios:

| Element | Foreground | Background | Ratio | Pass |
|---------|-----------|-----------|-------|------|
| User bubble text | #FFFFFF | #0066FF | 4.75:1 | AA |
| Agent bubble text | #1A1A1A | #F0F0F0 | 14.5:1 | AAA |
| Card title | #1A1A1A | #FFFFFF | 17.4:1 | AAA |
| Card body | #555555 | #FFFFFF | 7.5:1 | AAA |
| Error text | #CC0000 | #FFF3F3 | 5.2:1 | AA |
| Button text (primary) | #FFFFFF | #0066FF | 4.75:1 | AA |
| Button text (secondary) | #333333 | #FFFFFF | 12.6:1 | AAA |
| Button text (danger) | #CC0000 | #FFFFFF | 5.5:1 | AA |

---

## Focus Management

| Scenario | Behavior |
|----------|----------|
| Page load | Focus on message input |
| After sending a message | Focus returns to message input |
| After error | Focus stays on input (error is announced via `role="alert"`) |
| Carousel scroll | Focus stays on nav button; cards scroll visually |
| Form submit | Focus moves to first field of next response or input |
| Button click (reply) | Message is sent, focus returns to input |
| Button click (link) | New tab opens, focus stays in current page |

---

## Screen Reader Behavior

| Event | Announcement |
|-------|-------------|
| User sends message | No announcement (user initiated) |
| Agent responds with text | "[Agent message text]" (via `aria-live="polite"`) |
| Agent responds with format | Card/list/form title is announced |
| Loading starts | "Agent is thinking" |
| Error occurs | Error message text (via `role="alert"`) |
| Session reconnecting | "Session expired. Reconnecting..." |

---

## Keyboard Shortcuts

| Key | Context | Action |
|-----|---------|--------|
| Enter | Message input | Send message |
| Shift+Enter | Message input | New line |
| Enter | List item (focused) | Activate item action |
| Enter | Button (focused) | Click button |
| Tab | Anywhere | Move to next focusable element |
| Shift+Tab | Anywhere | Move to previous focusable element |

---

## Testing Checklist

Run these before shipping:

- [ ] Navigate the entire chat using only keyboard (no mouse)
- [ ] Send a message and verify focus returns to input
- [ ] Tab through a rendered InAppList and activate an item with Enter
- [ ] Fill out an InAppForm using only keyboard, verify validation errors are announced
- [ ] Scroll the InAppCarousel using nav buttons with keyboard
- [ ] Run axe-core or Lighthouse accessibility audit (target: 0 violations)
- [ ] Test with VoiceOver (macOS) or NVDA (Windows) — verify all formats are navigable
- [ ] Verify color contrast meets AA ratios (use browser DevTools)
- [ ] Resize to 200% zoom — verify no content is clipped or overlapping

---

## CSP Requirements (Node path only)

For portals NOT hosted on Salesforce (React, Angular, native):

```
Content-Security-Policy:
  default-src 'self';
  script-src 'self';
  style-src 'self' 'unsafe-inline';
  img-src 'self' https:;
  connect-src 'self' https://your-proxy-domain.com;
  font-src 'self';
```

**Critical:** Do NOT add `*.salesforce.com` or `*.force.com` to `connect-src`. The browser must never talk to Salesforce directly — all calls go through the proxy.

The LWC path (Experience Cloud) doesn't need custom CSP — Salesforce manages it.
