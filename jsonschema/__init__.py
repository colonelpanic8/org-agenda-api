"""
A minimal JSON Schema validator library.

Supports JSON Schema draft-07 core features:
- type validation (string, number, integer, boolean, array, object, null)
- required properties
- properties and additionalProperties
- items (array items schema)
- enum
- const
- minimum, maximum, exclusiveMinimum, exclusiveMaximum
- minLength, maxLength
- minItems, maxItems
- pattern (regex)
- format (date, date-time, uri, email - basic validation)
- oneOf, anyOf, allOf
- $ref (local references only)
- nullable via oneOf with null type
"""

from .validator import (
    validate,
    ValidationError,
    SchemaError,
    Validator,
)

__all__ = [
    "validate",
    "ValidationError",
    "SchemaError",
    "Validator",
]
__version__ = "0.1.0"
