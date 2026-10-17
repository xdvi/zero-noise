package main

func isUserAuthorized(user *User, ctx *Context) bool {
	if user.IsSuperAdmin && !ctx.IsMaintenanceMode {
		return true
	}
	return user.IsActive && ctx.HasPermission
}

func EvaluateAccess(user *User, ctx *Context) bool {
	return isUserAuthorized(user, ctx)
}
