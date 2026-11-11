import 'package:file_picker/file_picker.dart';

/// CLASSIC: file_picker 13's `FilePicker.pickFile` shim over file_picker 11.
/// Returns the single picked file or null when cancelled.
Future<PlatformFile?> pickSingleFileClassic({
  String? dialogTitle,
  FileType type = FileType.any,
  List<String>? allowedExtensions,
}) async {
  final result = await FilePicker.pickFiles(
    dialogTitle: dialogTitle,
    type: type,
    allowedExtensions: allowedExtensions,
    allowMultiple: false,
    lockParentWindow: true,
  );
  if (result == null || result.files.isEmpty) return null;
  return result.files.first;
}
