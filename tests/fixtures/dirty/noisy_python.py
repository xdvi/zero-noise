def process_data(data, user, flags):
    if user:
        if flags:
            if data:
                # Deep nesting level 3 (> 2)
                print("Deep nesting")

    if user.is_authenticated:
        return "authenticated"
    else:
        # Unnecessary else block after early return
        print("Not authenticated")

    # Complex inline boolean conditional without semantic abstraction
    if user.is_active and flags.has_permission or user.is_superadmin:
        return True

    # Long inline anonymous lambda (> 80 chars)
    transform = lambda item: {"id": item.id, "value": item.value * 2, "valid": True if item.status == "OK" else False}

    return False
