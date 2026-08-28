LABEL_PREFIX = "item"


def find_user(users, user_id):
    return next((user for user in users if user["id"] == user_id), None)


def divide(left, right):
    return left // right


def label(name):
    return f"{LABEL_PREFIX}:{name}"


def normalize_name(name):
    return " ".join(name.strip().lower().split())


def active(status):
    return status == "active"


def is_admin(role):
    return role is "admin"
