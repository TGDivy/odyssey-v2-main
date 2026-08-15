"""Top-level API router."""

from fastapi import APIRouter

from odyssey.api.attachments import router as attachments_router
from odyssey.api.auth import router as auth_router
from odyssey.api.captures import router as captures_router
from odyssey.api.sync import router as sync_router
from odyssey.api.system import router as system_router

router = APIRouter()
router.include_router(system_router)
router.include_router(auth_router)
router.include_router(captures_router)
router.include_router(sync_router)
router.include_router(attachments_router)
