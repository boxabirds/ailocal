from utils import format_user_record, shout

def create_user(uid, name, email):
    rec = format_user_record(uid, name, email)
    return rec

def announce(s):
    return shout(s)

if __name__ == "__main__":
    print(create_user(1, "  Alice  ", "ALICE@x.com"))
    print(announce("hi"))
