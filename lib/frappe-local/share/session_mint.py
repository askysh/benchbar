# The Frappe session of a user, made without a password. One body for two
# callers: open-as.sh splices this file into the snippet of `open --as`, and
# signin.py imports it for the sharing gateway. The caller has already
# checked who may be signed in; row is the User's name, first_name and
# last_name.
#
# The steps of frappe's LoginManager.post_login (auth.py) without
# set_user_info: that one only sets the response cookies, which the
# browser's own /login?sid= request sets, and computes the default page by
# importing every app (six of the seven seconds of a login on a bench with
# Insights). on_login hooks, the IP and hour restrictions and the session
# itself run as in a real login. Raises frappe.AuthenticationError when
# Frappe refuses; returns (full_name, sid).
def mint_session(frappe, row):
    from frappe.auth import CookieManager, LoginManager, validate_ip_address
    frappe.utils.set_request(path="/")
    frappe.local.cookie_manager = CookieManager()
    login = LoginManager()
    login.user = row.name
    login.run_trigger("on_login")
    validate_ip_address(row.name)
    login.validate_hour()
    login.get_user_info()
    login.full_name = " ".join(filter(None, [row.first_name, row.last_name]))
    login.make_session()
    login.setup_boot_cache()
    frappe.db.commit()
    return login.full_name, frappe.session.sid
