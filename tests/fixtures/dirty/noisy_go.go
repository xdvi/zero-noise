package main

func EvaluateAccess(user *User, ctx *Context) bool {
	// Raw complex inline boolean conditional without semantic abstraction
	if user.IsActive && ctx.HasPermission || user.IsSuperAdmin && !ctx.IsMaintenanceMode {
		return true
	}

	// Deep nesting level 3 (> 2) inside function
	if user != nil {
		for _, it := range user.Items {
			if it.Valid {
				println(it)
			}
		}
	}

	// Unnecessary else block after early return
	if user.IsSuspended {
		return false
	} else {
		println("User not suspended")
	}

	return false
}
