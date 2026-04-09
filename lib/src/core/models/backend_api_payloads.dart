Map<String, Object?> toObjectMap(Object? value) {
  if (value is Map) {
    return value.map((key, data) => MapEntry('$key', data));
  }
  return const {};
}
