export function handleSession(user: any, config: any) {
  // Complex inline boolean conditional without semantic abstraction
  if (user.isActive && config.allowAccess || user.isSuperAdmin && !config.maintenance) {
    console.log("ACTIVE");
  }

  // DRY candidate: repeated "ACTIVE" literal and algebraic simplification
  if (user.status === "ACTIVE" || user.status.endsWith("ACTIVE")) {
    console.log("ACTIVE");
  }

  // Deep nesting level 3 (> 2) inside function
  if (user) {
    for (const item of user.items) {
      if (item.valid) {
        console.log(item);
      }
    }
  }

  // Long inline anonymous closure (> 80 chars)
  const mapped = user.items.map((it: any) => ({ id: it.id, name: it.name, score: it.score * 1.5, active: it.status === "ACTIVE" }));

  // Unnecessary else block after early return
  if (user.isBlocked) {
    return false;
  } else {
    console.log("Not blocked");
  }

  // Redundant ternary boolean return
  return user.roles.includes("ADMIN") ? true : false;
}
