"""FastAPI dependencies for explicit database transaction boundaries."""

from collections.abc import AsyncIterator
from typing import Annotated, cast

from fastapi import Depends, Request
from sqlalchemy.ext.asyncio import AsyncSession

from odyssey.attachments.service import UploadTokenSigner
from odyssey.attachments.storage import LocalAttachmentStore
from odyssey.db.session import Database


def get_database(request: Request) -> Database:
    return cast(Database, request.app.state.database)


DatabaseDependency = Annotated[Database, Depends(get_database)]


async def get_session(database: DatabaseDependency) -> AsyncIterator[AsyncSession]:
    async with database.sessions() as session:
        yield session


SessionDependency = Annotated[AsyncSession, Depends(get_session)]


def get_attachment_store(request: Request) -> LocalAttachmentStore:
    return cast(LocalAttachmentStore, request.app.state.attachment_store)


AttachmentStoreDependency = Annotated[LocalAttachmentStore, Depends(get_attachment_store)]


def get_upload_token_signer(request: Request) -> UploadTokenSigner:
    return cast(UploadTokenSigner, request.app.state.upload_token_signer)


UploadTokenSignerDependency = Annotated[UploadTokenSigner, Depends(get_upload_token_signer)]
