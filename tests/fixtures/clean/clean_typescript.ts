interface UserItem {
  id: string;
  name: string;
  score: number;
  status: string;
}

function toScoredItem(it: UserItem) {
  return {
    id: it.id,
    name: it.name,
    score: it.score * 1.5,
    active: it.status === "ACTIVE",
  };
}

function canAccessSession(user: any, config: any): boolean {
  if (user.isSuperAdmin && !config.maintenance) {
    return true;
  }
  return user.isActive && config.allowAccess;
}

export function handleSession(user: any, config: any): boolean {
  if (canAccessSession(user, config)) {
    console.log("Access granted");
  }

  const mapped = user.items.map(toScoredItem);
  return user.roles.includes("ADMIN");
}
