"""Tests for the JSON Schema validator."""

import pytest
from jsonschema import validate, ValidationError, SchemaError


class TestTypeValidation:
    """Tests for type validation."""

    def test_string_type(self):
        validate("hello", {"type": "string"})

    def test_string_type_rejects_number(self):
        with pytest.raises(ValidationError, match="Expected type string, got int"):
            validate(42, {"type": "string"})

    def test_number_type(self):
        validate(42, {"type": "number"})
        validate(3.14, {"type": "number"})

    def test_number_type_rejects_string(self):
        with pytest.raises(ValidationError, match="Expected type number, got str"):
            validate("42", {"type": "number"})

    def test_integer_type(self):
        validate(42, {"type": "integer"})

    def test_integer_type_rejects_float(self):
        with pytest.raises(ValidationError, match="Expected type integer, got float"):
            validate(3.14, {"type": "integer"})

    def test_boolean_type(self):
        validate(True, {"type": "boolean"})
        validate(False, {"type": "boolean"})

    def test_boolean_not_confused_with_int(self):
        # In Python, bool is subclass of int, but for JSON Schema they're distinct
        with pytest.raises(ValidationError, match="Expected type boolean, got int"):
            validate(1, {"type": "boolean"})

    def test_array_type(self):
        validate([1, 2, 3], {"type": "array"})
        validate([], {"type": "array"})

    def test_object_type(self):
        validate({"a": 1}, {"type": "object"})
        validate({}, {"type": "object"})

    def test_null_type(self):
        validate(None, {"type": "null"})

    def test_multiple_types(self):
        schema = {"type": ["string", "null"]}
        validate("hello", schema)
        validate(None, schema)

    def test_multiple_types_rejects_non_matching(self):
        schema = {"type": ["string", "null"]}
        with pytest.raises(ValidationError):
            validate(42, schema)


class TestNumericConstraints:
    """Tests for numeric constraints."""

    def test_minimum(self):
        validate(5, {"type": "number", "minimum": 0})
        validate(0, {"type": "number", "minimum": 0})

    def test_minimum_fails(self):
        with pytest.raises(ValidationError, match="less than minimum"):
            validate(-1, {"type": "number", "minimum": 0})

    def test_maximum(self):
        validate(5, {"type": "number", "maximum": 10})
        validate(10, {"type": "number", "maximum": 10})

    def test_maximum_fails(self):
        with pytest.raises(ValidationError, match="greater than maximum"):
            validate(11, {"type": "number", "maximum": 10})

    def test_exclusive_minimum(self):
        validate(1, {"type": "number", "exclusiveMinimum": 0})

    def test_exclusive_minimum_fails_at_boundary(self):
        with pytest.raises(ValidationError, match="not greater than"):
            validate(0, {"type": "number", "exclusiveMinimum": 0})

    def test_exclusive_maximum(self):
        validate(9, {"type": "number", "exclusiveMaximum": 10})

    def test_exclusive_maximum_fails_at_boundary(self):
        with pytest.raises(ValidationError, match="not less than"):
            validate(10, {"type": "number", "exclusiveMaximum": 10})


class TestStringConstraints:
    """Tests for string constraints."""

    def test_min_length(self):
        validate("abc", {"type": "string", "minLength": 3})
        validate("abcd", {"type": "string", "minLength": 3})

    def test_min_length_fails(self):
        with pytest.raises(ValidationError, match="less than minLength"):
            validate("ab", {"type": "string", "minLength": 3})

    def test_max_length(self):
        validate("abc", {"type": "string", "maxLength": 5})
        validate("abcde", {"type": "string", "maxLength": 5})

    def test_max_length_fails(self):
        with pytest.raises(ValidationError, match="greater than maxLength"):
            validate("abcdef", {"type": "string", "maxLength": 5})

    def test_pattern(self):
        validate("abc123", {"type": "string", "pattern": "^[a-z]+[0-9]+$"})

    def test_pattern_fails(self):
        with pytest.raises(ValidationError, match="does not match pattern"):
            validate("123abc", {"type": "string", "pattern": "^[a-z]+[0-9]+$"})

    def test_format_date(self):
        validate("2024-01-15", {"type": "string", "format": "date"})

    def test_format_date_fails(self):
        with pytest.raises(ValidationError, match="not a valid date"):
            validate("01-15-2024", {"type": "string", "format": "date"})

    def test_format_datetime(self):
        validate("2024-01-15T10:30:00", {"type": "string", "format": "date-time"})
        validate("2024-01-15T10:30:00Z", {"type": "string", "format": "date-time"})
        validate("2024-01-15T10:30:00+05:00", {"type": "string", "format": "date-time"})

    def test_format_datetime_fails(self):
        with pytest.raises(ValidationError, match="not a valid datetime"):
            validate("2024-01-15 10:30:00", {"type": "string", "format": "date-time"})


class TestArrayConstraints:
    """Tests for array constraints."""

    def test_min_items(self):
        validate([1, 2, 3], {"type": "array", "minItems": 2})

    def test_min_items_fails(self):
        with pytest.raises(ValidationError, match="less than minItems"):
            validate([1], {"type": "array", "minItems": 2})

    def test_max_items(self):
        validate([1, 2], {"type": "array", "maxItems": 3})

    def test_max_items_fails(self):
        with pytest.raises(ValidationError, match="greater than maxItems"):
            validate([1, 2, 3, 4], {"type": "array", "maxItems": 3})

    def test_items_schema(self):
        schema = {"type": "array", "items": {"type": "integer"}}
        validate([1, 2, 3], schema)

    def test_items_schema_fails(self):
        schema = {"type": "array", "items": {"type": "integer"}}
        with pytest.raises(ValidationError, match=r"\[1\].*Expected type integer"):
            validate([1, "two", 3], schema)

    def test_unique_items(self):
        validate([1, 2, 3], {"type": "array", "uniqueItems": True})

    def test_unique_items_fails(self):
        with pytest.raises(ValidationError, match="not unique"):
            validate([1, 2, 1], {"type": "array", "uniqueItems": True})


class TestObjectConstraints:
    """Tests for object constraints."""

    def test_required_properties(self):
        schema = {"type": "object", "required": ["name"]}
        validate({"name": "Alice"}, schema)

    def test_required_properties_fails(self):
        schema = {"type": "object", "required": ["name"]}
        with pytest.raises(ValidationError, match="Missing required property: name"):
            validate({"age": 30}, schema)

    def test_properties_validation(self):
        schema = {
            "type": "object",
            "properties": {
                "name": {"type": "string"},
                "age": {"type": "integer"},
            },
        }
        validate({"name": "Alice", "age": 30}, schema)

    def test_properties_validation_fails(self):
        schema = {
            "type": "object",
            "properties": {
                "age": {"type": "integer"},
            },
        }
        with pytest.raises(ValidationError, match="age.*Expected type integer"):
            validate({"age": "thirty"}, schema)

    def test_additional_properties_false(self):
        schema = {
            "type": "object",
            "properties": {"name": {"type": "string"}},
            "additionalProperties": False,
        }
        validate({"name": "Alice"}, schema)

    def test_additional_properties_false_fails(self):
        schema = {
            "type": "object",
            "properties": {"name": {"type": "string"}},
            "additionalProperties": False,
        }
        with pytest.raises(ValidationError, match="Additional property not allowed: age"):
            validate({"name": "Alice", "age": 30}, schema)

    def test_additional_properties_schema(self):
        schema = {
            "type": "object",
            "properties": {"name": {"type": "string"}},
            "additionalProperties": {"type": "integer"},
        }
        validate({"name": "Alice", "score": 100}, schema)

    def test_additional_properties_schema_fails(self):
        schema = {
            "type": "object",
            "properties": {"name": {"type": "string"}},
            "additionalProperties": {"type": "integer"},
        }
        with pytest.raises(ValidationError, match="score.*Expected type integer"):
            validate({"name": "Alice", "score": "high"}, schema)


class TestEnumAndConst:
    """Tests for enum and const validation."""

    def test_enum(self):
        validate("red", {"enum": ["red", "green", "blue"]})

    def test_enum_fails(self):
        with pytest.raises(ValidationError, match="not in enum"):
            validate("yellow", {"enum": ["red", "green", "blue"]})

    def test_const(self):
        validate(42, {"const": 42})

    def test_const_fails(self):
        with pytest.raises(ValidationError, match="Expected constant"):
            validate(43, {"const": 42})


class TestComposition:
    """Tests for oneOf, anyOf, allOf."""

    def test_one_of(self):
        schema = {
            "oneOf": [
                {"type": "integer", "minimum": 0},
                {"type": "string", "minLength": 1},
            ]
        }
        validate(5, schema)
        validate("hello", schema)

    def test_one_of_fails_none_match(self):
        schema = {
            "oneOf": [
                {"type": "integer", "minimum": 0},
                {"type": "string", "minLength": 1},
            ]
        }
        with pytest.raises(ValidationError, match="does not match any oneOf"):
            validate(-5, schema)

    def test_any_of(self):
        schema = {
            "anyOf": [
                {"type": "integer"},
                {"type": "string"},
            ]
        }
        validate(5, schema)
        validate("hello", schema)

    def test_any_of_fails(self):
        schema = {
            "anyOf": [
                {"type": "integer"},
                {"type": "string"},
            ]
        }
        with pytest.raises(ValidationError, match="does not match any anyOf"):
            validate([1, 2, 3], schema)

    def test_all_of(self):
        schema = {
            "allOf": [
                {"type": "object", "required": ["name"]},
                {"type": "object", "required": ["age"]},
            ]
        }
        validate({"name": "Alice", "age": 30}, schema)

    def test_all_of_fails(self):
        schema = {
            "allOf": [
                {"type": "object", "required": ["name"]},
                {"type": "object", "required": ["age"]},
            ]
        }
        with pytest.raises(ValidationError, match="does not match allOf"):
            validate({"name": "Alice"}, schema)


class TestReferences:
    """Tests for $ref resolution."""

    def test_ref_to_definitions(self):
        schema = {
            "type": "object",
            "properties": {
                "user": {"$ref": "#/definitions/User"},
            },
            "definitions": {
                "User": {
                    "type": "object",
                    "properties": {"name": {"type": "string"}},
                    "required": ["name"],
                }
            },
        }
        validate({"user": {"name": "Alice"}}, schema)

    def test_ref_to_definitions_fails(self):
        schema = {
            "type": "object",
            "properties": {
                "user": {"$ref": "#/definitions/User"},
            },
            "definitions": {
                "User": {
                    "type": "object",
                    "required": ["name"],
                }
            },
        }
        with pytest.raises(ValidationError, match="Missing required property: name"):
            validate({"user": {}}, schema)

    def test_unknown_ref_raises_schema_error(self):
        schema = {
            "type": "object",
            "properties": {
                "user": {"$ref": "#/definitions/Unknown"},
            },
            "definitions": {},
        }
        with pytest.raises(SchemaError, match="Unknown definition"):
            validate({"user": {}}, schema)


class TestNullable:
    """Tests for nullable pattern using oneOf."""

    def test_nullable_string(self):
        schema = {
            "oneOf": [
                {"type": "string"},
                {"type": "null"},
            ]
        }
        validate("hello", schema)
        validate(None, schema)

    def test_nullable_object(self):
        schema = {
            "oneOf": [
                {"type": "object", "properties": {"id": {"type": "integer"}}},
                {"type": "null"},
            ]
        }
        validate({"id": 1}, schema)
        validate(None, schema)


class TestErrorPaths:
    """Tests for error path reporting."""

    def test_nested_object_path(self):
        schema = {
            "type": "object",
            "properties": {
                "user": {
                    "type": "object",
                    "properties": {
                        "name": {"type": "string"},
                    },
                },
            },
        }
        with pytest.raises(ValidationError) as exc_info:
            validate({"user": {"name": 123}}, schema)
        assert "user.name" in str(exc_info.value)

    def test_array_index_path(self):
        schema = {
            "type": "array",
            "items": {"type": "string"},
        }
        with pytest.raises(ValidationError) as exc_info:
            validate(["a", "b", 3], schema)
        assert "[2]" in str(exc_info.value)

    def test_mixed_path(self):
        schema = {
            "type": "object",
            "properties": {
                "items": {
                    "type": "array",
                    "items": {"type": "integer"},
                },
            },
        }
        with pytest.raises(ValidationError) as exc_info:
            validate({"items": [1, 2, "three"]}, schema)
        assert "items[2]" in str(exc_info.value)


class TestEmptySchema:
    """Tests for edge cases."""

    def test_empty_schema_accepts_anything(self):
        validate("anything", {})
        validate(123, {})
        validate(None, {})
        validate([1, 2, 3], {})
        validate({"a": 1}, {})
