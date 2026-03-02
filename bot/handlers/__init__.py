"""Routers aggregator for the bot."""

from .user import user_router
from .admin import admin_router



def get_routers():
    return [user_router, admin_router]
