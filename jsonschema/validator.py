"""
JSON Schema validator implementation.
"""

import re
from typing import Any


class ValidationError(Exception):
    """Raised when validation fails."""

    def __init__(self, message: str, path: list[str | int] | None = None):
        self.message = message
        self.path = path or []
        super().__init__(self._format_message())

    def _format_message(self) -> str:
        if self.path:
            path_str = "".join(
                f"[{p}]" if isinstance(p, int) else f".{p}" for p in self.path
            )
            if path_str.startswith("."):
                path_str = path_str[1:]
            return f"{path_str}: {self.message}"
        return self.message


class SchemaError(Exception):
    """Raised when the schema itself is invalid."""

    pass


# Regex patterns for format validation
DATE_PATTERN = re.compile(r"^\d{4}-\d{2}-\d{2}$")
DATETIME_PATTERN = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})?$")
URI_PATTERN = re.compile(r"^[a-zA-Z][a-zA-Z0-9+.-]*://")
EMAIL_PATTERN = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")


class Validator:
    """
    JSON Schema validator.

    Supports a subset of JSON Schema draft-07.
    """

    def __init__(self, schema: dict, definitions: dict | None = None):
        """
        Initialize validator with a schema.

        Args:
            schema: The JSON Schema to validate against
            definitions: Optional shared definitions (for $ref resolution)
        """
        if not isinstance(schema, dict):
            raise SchemaError("Schema must be a dictionary")
        self.schema = schema
        self.definitions = definitions or schema.get("definitions", schema.get("$defs", {}))

    def validate(self, instance: Any) -> None:
        """
        Validate an instance against the schema.

        Args:
            instance: The data to validate

        Raises:
            ValidationError: If validation fails
        """
        self._validate(instance, self.schema, [])

    def _validate(self, instance: Any, schema: dict, path: list) -> None:
        """Internal validation with path tracking."""
        if not isinstance(schema, dict):
            raise SchemaError(f"Schema at {path} must be a dictionary")

        # Handle $ref
        if "$ref" in schema:
            ref = schema["$ref"]
            if ref.startswith("#/definitions/"):
                def_name = ref[len("#/definitions/") :]
                if def_name not in self.definitions:
                    raise SchemaError(f"Unknown definition: {def_name}")
                schema = self.definitions[def_name]
            elif ref.startswith("#/$defs/"):
                def_name = ref[len("#/$defs/") :]
                if def_name not in self.definitions:
                    raise SchemaError(f"Unknown definition: {def_name}")
                schema = self.definitions[def_name]
            else:
                raise SchemaError(f"Unsupported $ref format: {ref}")

        # Handle boolean schema
        if schema == {} or schema is True:
            return
        if schema is False:
            raise ValidationError("Schema rejects all values", path)

        # Handle const
        if "const" in schema:
            if instance != schema["const"]:
                raise ValidationError(
                    f"Expected constant {schema['const']!r}, got {instance!r}", path
                )

        # Handle enum
        if "enum" in schema:
            if instance not in schema["enum"]:
                raise ValidationError(
                    f"Value {instance!r} not in enum {schema['enum']}", path
                )

        # Handle type
        if "type" in schema:
            self._validate_type(instance, schema["type"], path)

        # Handle numeric constraints
        if isinstance(instance, (int, float)) and not isinstance(instance, bool):
            self._validate_numeric(instance, schema, path)

        # Handle string constraints
        if isinstance(instance, str):
            self._validate_string(instance, schema, path)

        # Handle array constraints
        if isinstance(instance, list):
            self._validate_array(instance, schema, path)

        # Handle object constraints
        if isinstance(instance, dict):
            self._validate_object(instance, schema, path)

        # Handle oneOf
        if "oneOf" in schema:
            self._validate_one_of(instance, schema["oneOf"], path)

        # Handle anyOf
        if "anyOf" in schema:
            self._validate_any_of(instance, schema["anyOf"], path)

        # Handle allOf
        if "allOf" in schema:
            self._validate_all_of(instance, schema["allOf"], path)

    def _validate_type(self, instance: Any, type_spec: str | list, path: list) -> None:
        """Validate the type constraint."""
        types = [type_spec] if isinstance(type_spec, str) else type_spec

        def check_type(t: str) -> bool:
            if t == "string":
                return isinstance(instance, str)
            if t == "number":
                return isinstance(instance, (int, float)) and not isinstance(instance, bool)
            if t == "integer":
                return isinstance(instance, int) and not isinstance(instance, bool)
            if t == "boolean":
                return isinstance(instance, bool)
            if t == "array":
                return isinstance(instance, list)
            if t == "object":
                return isinstance(instance, dict)
            if t == "null":
                return instance is None
            raise SchemaError(f"Unknown type: {t}")

        if not any(check_type(t) for t in types):
            actual_type = type(instance).__name__
            if instance is None:
                actual_type = "null"
            raise ValidationError(
                f"Expected type {type_spec}, got {actual_type}", path
            )

    def _validate_numeric(self, instance: int | float, schema: dict, path: list) -> None:
        """Validate numeric constraints."""
        if "minimum" in schema and instance < schema["minimum"]:
            raise ValidationError(
                f"Value {instance} is less than minimum {schema['minimum']}", path
            )
        if "maximum" in schema and instance > schema["maximum"]:
            raise ValidationError(
                f"Value {instance} is greater than maximum {schema['maximum']}", path
            )
        if "exclusiveMinimum" in schema and instance <= schema["exclusiveMinimum"]:
            raise ValidationError(
                f"Value {instance} is not greater than {schema['exclusiveMinimum']}", path
            )
        if "exclusiveMaximum" in schema and instance >= schema["exclusiveMaximum"]:
            raise ValidationError(
                f"Value {instance} is not less than {schema['exclusiveMaximum']}", path
            )

    def _validate_string(self, instance: str, schema: dict, path: list) -> None:
        """Validate string constraints."""
        if "minLength" in schema and len(instance) < schema["minLength"]:
            raise ValidationError(
                f"String length {len(instance)} is less than minLength {schema['minLength']}", path
            )
        if "maxLength" in schema and len(instance) > schema["maxLength"]:
            raise ValidationError(
                f"String length {len(instance)} is greater than maxLength {schema['maxLength']}", path
            )
        if "pattern" in schema:
            if not re.search(schema["pattern"], instance):
                raise ValidationError(
                    f"String does not match pattern {schema['pattern']!r}", path
                )
        if "format" in schema:
            self._validate_format(instance, schema["format"], path)

    def _validate_format(self, instance: str, format_name: str, path: list) -> None:
        """Validate string format."""
        if format_name == "date":
            if not DATE_PATTERN.match(instance):
                raise ValidationError(
                    f"String {instance!r} is not a valid date (YYYY-MM-DD)", path
                )
        elif format_name == "date-time":
            if not DATETIME_PATTERN.match(instance):
                raise ValidationError(
                    f"String {instance!r} is not a valid datetime", path
                )
        elif format_name == "uri":
            if not URI_PATTERN.match(instance):
                raise ValidationError(
                    f"String {instance!r} is not a valid URI", path
                )
        elif format_name == "email":
            if not EMAIL_PATTERN.match(instance):
                raise ValidationError(
                    f"String {instance!r} is not a valid email", path
                )
        # Other formats are ignored (per spec, format is an annotation by default)

    def _validate_array(self, instance: list, schema: dict, path: list) -> None:
        """Validate array constraints."""
        if "minItems" in schema and len(instance) < schema["minItems"]:
            raise ValidationError(
                f"Array length {len(instance)} is less than minItems {schema['minItems']}", path
            )
        if "maxItems" in schema and len(instance) > schema["maxItems"]:
            raise ValidationError(
                f"Array length {len(instance)} is greater than maxItems {schema['maxItems']}", path
            )
        if "items" in schema:
            items_schema = schema["items"]
            for i, item in enumerate(instance):
                self._validate(item, items_schema, path + [i])
        if "uniqueItems" in schema and schema["uniqueItems"]:
            # Convert items to tuples for hashability (for dicts)
            try:
                seen = set()
                for item in instance:
                    key = self._make_hashable(item)
                    if key in seen:
                        raise ValidationError("Array items are not unique", path)
                    seen.add(key)
            except TypeError:
                # If items are unhashable, do O(n^2) comparison
                for i, item in enumerate(instance):
                    for j, other in enumerate(instance[i + 1 :], i + 1):
                        if item == other:
                            raise ValidationError("Array items are not unique", path)

    def _make_hashable(self, value: Any) -> Any:
        """Convert a value to a hashable form for uniqueItems check."""
        if isinstance(value, dict):
            return tuple(sorted((k, self._make_hashable(v)) for k, v in value.items()))
        if isinstance(value, list):
            return tuple(self._make_hashable(v) for v in value)
        return value

    def _validate_object(self, instance: dict, schema: dict, path: list) -> None:
        """Validate object constraints."""
        # Check required properties
        if "required" in schema:
            for prop in schema["required"]:
                if prop not in instance:
                    raise ValidationError(f"Missing required property: {prop}", path)

        # Validate properties
        properties = schema.get("properties", {})
        pattern_properties = schema.get("patternProperties", {})
        additional_properties = schema.get("additionalProperties", True)

        for prop, value in instance.items():
            prop_path = path + [prop]
            validated = False

            # Check against properties
            if prop in properties:
                self._validate(value, properties[prop], prop_path)
                validated = True

            # Check against patternProperties
            for pattern, prop_schema in pattern_properties.items():
                if re.search(pattern, prop):
                    self._validate(value, prop_schema, prop_path)
                    validated = True

            # Check additionalProperties
            if not validated:
                if additional_properties is False:
                    raise ValidationError(
                        f"Additional property not allowed: {prop}", path
                    )
                elif isinstance(additional_properties, dict):
                    self._validate(value, additional_properties, prop_path)

        # Check minProperties and maxProperties
        if "minProperties" in schema and len(instance) < schema["minProperties"]:
            raise ValidationError(
                f"Object has {len(instance)} properties, minimum is {schema['minProperties']}", path
            )
        if "maxProperties" in schema and len(instance) > schema["maxProperties"]:
            raise ValidationError(
                f"Object has {len(instance)} properties, maximum is {schema['maxProperties']}", path
            )

    def _validate_one_of(self, instance: Any, schemas: list, path: list) -> None:
        """Validate oneOf constraint (exactly one must match)."""
        matches = 0
        errors = []
        for i, sub_schema in enumerate(schemas):
            try:
                self._validate(instance, sub_schema, path)
                matches += 1
            except ValidationError as e:
                errors.append(f"  [{i}]: {e.message}")

        if matches == 0:
            error_details = "\n".join(errors)
            raise ValidationError(
                f"Value does not match any oneOf schema:\n{error_details}", path
            )
        if matches > 1:
            raise ValidationError(
                f"Value matches {matches} oneOf schemas (expected exactly 1)", path
            )

    def _validate_any_of(self, instance: Any, schemas: list, path: list) -> None:
        """Validate anyOf constraint (at least one must match)."""
        errors = []
        for i, sub_schema in enumerate(schemas):
            try:
                self._validate(instance, sub_schema, path)
                return  # Success - at least one matched
            except ValidationError as e:
                errors.append(f"  [{i}]: {e.message}")

        error_details = "\n".join(errors)
        raise ValidationError(
            f"Value does not match any anyOf schema:\n{error_details}", path
        )

    def _validate_all_of(self, instance: Any, schemas: list, path: list) -> None:
        """Validate allOf constraint (all must match)."""
        for i, sub_schema in enumerate(schemas):
            try:
                self._validate(instance, sub_schema, path)
            except ValidationError as e:
                raise ValidationError(
                    f"Value does not match allOf schema [{i}]: {e.message}", path
                )


def validate(instance: Any, schema: dict) -> None:
    """
    Validate an instance against a JSON Schema.

    Args:
        instance: The data to validate
        schema: The JSON Schema

    Raises:
        ValidationError: If validation fails
        SchemaError: If the schema is invalid
    """
    Validator(schema).validate(instance)
