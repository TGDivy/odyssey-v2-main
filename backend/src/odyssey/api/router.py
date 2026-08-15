"""Top-level API router."""

from fastapi import APIRouter

from odyssey.api.system import router as system_router

router = APIRouter()
router.include_router(system_router)
