"""Top-level API router."""

from fastapi import APIRouter

from odyssey.api.attachments import router as attachments_router
from odyssey.api.auth import router as auth_router
from odyssey.api.captures import router as captures_router
from odyssey.api.context import router as context_router
from odyssey.api.decisions import router as decisions_router
from odyssey.api.evidence import router as evidence_router
from odyssey.api.exports import router as exports_router
from odyssey.api.intents import router as intents_router
from odyssey.api.product import router as product_router
from odyssey.api.recommendations import router as recommendations_router
from odyssey.api.seasons import router as seasons_router
from odyssey.api.sync import router as sync_router
from odyssey.api.system import router as system_router

router = APIRouter()
router.include_router(system_router)
router.include_router(auth_router)
router.include_router(captures_router)
router.include_router(context_router)
router.include_router(decisions_router)
router.include_router(evidence_router)
router.include_router(exports_router)
router.include_router(intents_router)
router.include_router(product_router)
router.include_router(recommendations_router)
router.include_router(seasons_router)
router.include_router(sync_router)
router.include_router(attachments_router)
