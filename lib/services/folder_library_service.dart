import 'package:flutter/services.dart';

class FolderLibraryService {
  static const MethodChannel _channel =
      MethodChannel('com.mhasanzare82.audioplayer/folder_library');

  Future<Map<String, String>?> pickFolder() async {
    final result = await _channel.invokeMapMethod<String, dynamic>('pickFolder');
    if (result == null) return null;
    final uri = result['uri']?.toString();
    final name = result['name']?.toString();
    if (uri == null || name == null) return null;
    return {'uri': uri, 'name': name};
  }

  Future<List<Map<String, String>>> scanFolders(
    List<String> folderUris,
  ) async {
    final result = await _channel.invokeListMethod<dynamic>(
      'scanFolders',
      {'uris': folderUris},
    );
    if (result == null) return [];
    return result
        .whereType<Map>()
        .map((item) => {
              'uri': item['uri'].toString(),
              'name': item['name'].toString(),
            })
        .toList();
  }
}
