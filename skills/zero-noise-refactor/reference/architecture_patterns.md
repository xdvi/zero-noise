# Explicit Semantics and DRY Architecture Patterns

Architectural guide to structure expressive code, free of duplication and decoupled from infrastructure details.

## 1. Domain Semantics & Ubiquitous Language in Predicates

- Never expose raw compound boolean expressions in business logic (`if (a && !b && !c)`).
- Encapsulate them into descriptive functions that preserve the repository's **ubiquitous language** (`if (isEligibleForExpressCheckout(cart, user))`).
- **Never Synonymize Repo Vocabulary**: Reuse exact domain nouns and verbs already established in the codebase (do not invent `Shipping` when the module uses `Checkout`).
- **Propose When Ambiguous**: If the domain concept behind a compound condition is unclear or spans multiple concepts, propose candidate predicate names to the user and wait for approval before applying.

### Example

Before:

```typescript
if (cart.total > 100 && user.isVerified && !cart.hasRestrictedItems && user.country === 'CO') {
  enableExpressCheckout(cart);
}
```

After:

```typescript
function isEligibleForExpressCheckout(cart: Cart, user: User): boolean {
  const meetsMinimumOrder = cart.total > 100 && !cart.hasRestrictedItems;
  const isVerifiedDomesticUser = user.isVerified && user.country === 'CO';
  return meetsMinimumOrder && isVerifiedDomesticUser;
}

if (isEligibleForExpressCheckout(cart, user)) {
  enableExpressCheckout(cart);
}
```

## 2. Single Source of Truth (DRY in Constants and Environments)

- Centralize environment checks (e.g., `typeof window !== 'undefined'`, platform flags, env variables) and repeated literals in shared pure utilities or constants.
- If a data transformation appears in more than one place, extract it into a pure domain function.

## 3. Clean Break and Zero Legacy

- Do not leave dead adapters, backward compatibility flags, or obsolete code comments (`// TODO: remove old implementation`).
- Update contracts end-to-end so the codebase maintains a single canonical way to perform each operation.
