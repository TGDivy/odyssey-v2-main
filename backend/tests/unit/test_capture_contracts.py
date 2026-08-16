from datetime import UTC, datetime

import pytest
from pydantic import ValidationError

from odyssey.domain.capture import InterpretationReviewDisposition, InterpretationVersion
from odyssey.domain.common import new_uuid7


def test_interpretation_review_preserves_explicit_lineage() -> None:
    reviewed_version_id = new_uuid7()
    review = InterpretationVersion(
        id=new_uuid7(),
        interpreter="odyssey.owner-review",
        interpreter_version="1",
        created_at=datetime.now(UTC),
        status="interpreted",
        proposed_fields={"capture_type": {"value": "food"}},
        source_span_refs=("capture:source#original_payload",),
        supersedes_interpretation_version_id=reviewed_version_id,
        owner_review_disposition=InterpretationReviewDisposition.CORRECTED,
        owner_review_note="Owner corrected the explicit category.",
    )

    assert review.supersedes_interpretation_version_id == reviewed_version_id
    assert review.owner_review_disposition is InterpretationReviewDisposition.CORRECTED


@pytest.mark.parametrize(
    ("disposition", "status", "proposed_fields"),
    [
        (InterpretationReviewDisposition.ACCEPTED, "interpreted", {}),
        (InterpretationReviewDisposition.CORRECTED, "interpreted", {}),
        (InterpretationReviewDisposition.DISMISSED, "interpreted", {}),
        (InterpretationReviewDisposition.DISMISSED, "dismissed", {"capture_type": "food"}),
    ],
)
def test_interpretation_review_rejects_incoherent_semantics(
    disposition: InterpretationReviewDisposition,
    status: str,
    proposed_fields: dict[str, object],
) -> None:
    with pytest.raises(ValidationError):
        InterpretationVersion(
            id=new_uuid7(),
            interpreter="odyssey.owner-review",
            interpreter_version="1",
            created_at=datetime.now(UTC),
            status=status,
            proposed_fields=proposed_fields,
            supersedes_interpretation_version_id=new_uuid7(),
            owner_review_disposition=disposition,
        )
