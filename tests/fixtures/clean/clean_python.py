def has_user_access(user, flags):
    """Semantic domain predicate for authorization check."""
    if user.is_superadmin:
        return True
    return user.is_active and flags.has_permission


def transform_item(item):
    """Named pure function extracted outside inline closures."""
    return {
        "id": item.id,
        "value": item.value * 2,
        "valid": item.status == "OK",
    }


def process_data(data, user, flags):
    """Flattened processing with Early Return."""
    if not user or not flags or not data:
        return False

    if user.is_authenticated:
        return "authenticated"

    if has_user_access(user, flags):
        return True

    transformed = [transform_item(item) for item in data]
    return len(transformed) > 0
