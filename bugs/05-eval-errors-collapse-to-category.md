# hibrow bugs

## BUG-005: `eval` throws away the error message, reporting only a category

**Date:** 11/10/2026
**Severity:** Medium — `eval` is the primary debugging command, and every failing
expression returned a message with no diagnostic value, so a script could not tell a
typo from a null-deref from a syntax error
**Status:** Fixed (11/10/2026)
**Affected commands:** `eval` (and `wait`/`click`'s async eval), both Chrome and Firefox

### Symptom

Any expression that threw collapsed to a single useless string regardless of the actual
error:

```
$ hibrow eval p "nonexistentVar123"   -> Error: Uncaught            (chrome)
$ hibrow eval p "null.foo"            -> Error: Uncaught            (chrome)
$ hibrow eval p "throw new Error('boom')" -> Error: Uncaught        (chrome)
$ hibrow eval p "nonexistentVar123"   -> Error: javascript error    (firefox)
$ hibrow eval p "null.foo"            -> Error: javascript error    (firefox)
```

Reproducible 100% of the time — not a flake. The real cause (ReferenceError,
TypeError, SyntaxError, the thrown value) was discarded by the parser.

### Cause

Both engines return the diagnostic in a secondary field, and both code paths read only
the generic prefix:

- **Chrome (CDP `Runtime.evaluate`).** The reply is
  `exceptionDetails = {text:"Uncaught", exception:{description:"ReferenceError: … is not
  defined\n    at …", value, className, …}}`. The parser returned `exceptionDetails.text`,
  which is always the bare `"Uncaught"`; the message lives in `exception.description` (for
  Errors and numbers) or `exception.value` (for thrown string/primitive values).
- **Firefox (Marionette `WebDriver:ExecuteScript`).** The error object is
  `{error:"javascript error", message:"ReferenceError: … is not defined", stacktrace:"…"}`.
  The code returned `error`, the category; the message lives in `message`.

Confirmed by capturing the raw replies (a temporary `HIBROW_DEBUG_EXC` dump in each parse
path, since the eval runs in the daemon whose stderr is normally discarded), then reverted.

### Fix

- `cdp.zig parseEvalResult`: prefer `exception.description` (first line only, dropping the
  stack trace), then `exception.value` (thrown primitives), then fall back to `text`. The
  `"Uncaught"` prefix is kept so a thrown value still reads as an uncaught throw, matching
  the DevTools console (`Uncaught ReferenceError: …`, `Uncaught 42`).
- `marionette.zig`: `MarionetteResult.errorMessage` prefers `message` over the `error`
  category; both `eval` and `evalAsync` use it.

After the fix:

```
chrome:  Error: Uncaught ReferenceError: nonexistentVar123 is not defined
         Error: Uncaught TypeError: Cannot read properties of null (reading 'foo')
         Error: Uncaught SyntaxError: Function statements require a function name
         Error: Uncaught Error: boom          Error: Uncaught 42
firefox: Error: ReferenceError: nonexistentVar123 is not defined
         Error: TypeError: can't access property "foo" of null
         Error: Error: boom
```

### Regression test

`tests/e2e-features.sh` asserts, on both engines, that `eval` of an undefined variable
surfaces `ReferenceError` and names the offending identifier (`eval surfaces error msg`,
`eval error names ident`).
