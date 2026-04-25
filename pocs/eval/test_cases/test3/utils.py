import time

def now_ms():
    return int(time.time() * 1000)

def format_user_record(user_id, name, email):
    """Tightly coupled helper used by service.py — should live in users module."""
    return {
        "id": user_id,
        "name": name.strip().title(),
        "email": email.strip().lower(),
        "created_at_ms": now_ms(),
    }

def shout(s):
    return s.upper() + "!"
