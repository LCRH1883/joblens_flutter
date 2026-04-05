enum LibraryImportMode {
  move('move'),
  copy('copy');

  const LibraryImportMode(this.storageValue);

  final String storageValue;

  String get label => switch (this) {
    LibraryImportMode.move => 'Move into Joblens',
    LibraryImportMode.copy => 'Copy into Joblens',
  };

  static LibraryImportMode fromStorage(String? value) {
    return switch (value) {
      'move' => LibraryImportMode.move,
      _ => LibraryImportMode.copy,
    };
  }
}
