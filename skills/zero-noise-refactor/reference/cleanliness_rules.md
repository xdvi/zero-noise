# Zero-Noise and Readability Laws

These rules define the mandatory standards for eliminating syntactic and cognitive noise during refactoring.

## 1. Zero Noise in the Body (Inlining Ban)

- Never define lengthy anonymous functions or complex initialization logic inside constructors, UI hooks (`useState`, `useEffect`, `useMemo`), or route handlers.
- Extract all complex logic into independent, named pure functions passed by reference.

### Example (TypeScript)

Before (Inline noise):

```typescript
useEffect(() => {
  if (window.localStorage.getItem('token') && !isExpired(window.localStorage.getItem('token'))) {
    syncSession(window.localStorage.getItem('token'));
  }
}, []);
```

After (Zero noise, by reference):

```typescript
function syncActiveLocalSession(): void {
  const token = readStoredToken();
  if (!isValidSessionToken(token)) return;
  syncSession(token);
}

useEffect(syncActiveLocalSession, []);
```

## 2. Absolute Early Return (Guard Clauses)

- Eliminate unnecessary `else` blocks and nested `if` statements deeper than 2 levels.
- Invert conditions and return or throw early to keep the happy path left-aligned.

### Example (Python / Go / Rust / C#)

Before (Deep nesting pyramid):

```python
def process_order(order):
    if order is not None:
        if order.is_paid:
            if len(order.items) > 0:
                return dispatch(order)
            else:
                raise ValueError("No items in order")
        else:
            raise ValueError("Order not paid")
    return None
```

After (Flattened with Guard Clauses):

```python
def process_order(order):
    if order is None:
        return None
    if not order.is_paid:
        raise ValueError("Order not paid")
    if not order.items:
        raise ValueError("No items in order")

    return dispatch(order)
```

## 3. Algebraic and Boolean Simplification

- Eliminate logical redundancies (e.g., `x === '/path' || x.endsWith('/path')` reduces to `x.endsWith('/path')`).
- Avoid redundant explicit boolean returns (`if (cond) return true; else return false;` reduces to `return Boolean(cond);`).
- Apply De Morgan's laws to simplify multiple chained negations (`!(!a || !b)` becomes `a && b`).
