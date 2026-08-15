"""Configuration-driven attachment store construction."""

from odyssey.attachments.storage import AttachmentStore, LocalAttachmentStore
from odyssey.attachments.storage_gcs import GCSAttachmentStore
from odyssey.attachments.storage_s3 import S3AttachmentStore
from odyssey.config import AttachmentStoreBackend, Settings


def create_attachment_store(settings: Settings) -> AttachmentStore:
    if settings.attachment_store_backend is AttachmentStoreBackend.LOCAL:
        return LocalAttachmentStore(settings.attachment_storage_path)
    if settings.attachment_store_backend is AttachmentStoreBackend.S3:
        access_key = settings.storage_access_key.get_secret_value() or None
        secret_key = settings.storage_secret_key.get_secret_value() or None
        return S3AttachmentStore(
            bucket_name=settings.storage_bucket,
            region=settings.storage_region,
            endpoint_url=settings.storage_endpoint or None,
            access_key=access_key,
            secret_key=secret_key,
            force_path_style=settings.storage_force_path_style,
            server_side_encryption=settings.storage_server_side_encryption or None,
            kms_key_id=settings.storage_kms_key_id or None,
            require_versioning=settings.storage_require_versioning,
            require_public_access_block=settings.storage_require_public_access_block,
        )
    return GCSAttachmentStore(
        bucket_name=settings.storage_bucket,
        project_id=settings.gcp_project_id or None,
        kms_key_name=settings.storage_kms_key_id or None,
        require_versioning=settings.storage_require_versioning,
        require_uniform_bucket_access=settings.storage_require_public_access_block,
    )
