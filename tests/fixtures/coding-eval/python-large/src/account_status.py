def resolve_account_status(records, account_id):
    """Return the matching account status, or None when it is absent."""
    for record in records:
        if record["id"] == account_id:
            return record["status"]
    return None
