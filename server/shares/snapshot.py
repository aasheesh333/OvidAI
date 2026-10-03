"""Small explicit wire schema. Never accept a serialized session or Message."""

import re
from typing import Annotated, Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator

# Fail closed for known embedded reasoning/context/credential/byte envelopes.
# This is defense in depth, not a promise to identify arbitrary prose secrets.
PRIVATE_TEXT = re.compile(
    r'<\s*/?\s*(?:think|thinking|analysis|reasoning|system-reminder|internal|secret)\b'
    r'|\[(?:report from subagent|subagent |schedule |plugin hook context|'
    r'context |system |user attachments|previous phase result)'
    r'|\bBackground subagent\s'
    r'|\b(?:authorization\s*:|bearer\s+|api[_-]?key\s*[:=]|'
    r'password\s*[:=]|secret\s*[:=]|access[_-]?token\s*[:=])'
    r'|-----BEGIN [A-Z ]*PRIVATE KEY-----|data:[^\s,]*;base64,'
    r'|\b(?:sk-[A-Za-z0-9_-]{16,}|gh[pousr]_[A-Za-z0-9]{16,})'
    r'|(?:/data/(?:user|data)/|/root/|/home/|file://)', re.IGNORECASE)


class ShareMessage(BaseModel):
    model_config = ConfigDict(extra='forbid', frozen=True)
    role: Literal['user', 'assistant']
    content: Annotated[str, Field(min_length=1, max_length=20000, strict=True)]

    @field_validator('content')
    @classmethod
    def visible_text(cls, value):
        if not value.strip() or PRIVATE_TEXT.search(value):
            raise ValueError('Only visible public text may be shared')
        return value


class CreateShare(BaseModel):
    model_config = ConfigDict(extra='forbid')
    session_id: Annotated[str, Field(min_length=1, max_length=128, pattern=r'^[A-Za-z0-9_-]+$')]
    request_id: Annotated[str, Field(min_length=1, max_length=128, pattern=r'^[A-Za-z0-9_-]+$')]
    messages: Annotated[list[ShareMessage], Field(min_length=1, max_length=500)]

    @field_validator('messages')
    @classmethod
    def bounded_text(cls, messages):
        if sum(len(m.content.encode('utf-8')) for m in messages) > 200000:
            raise ValueError('Snapshot is too large')
        return messages
