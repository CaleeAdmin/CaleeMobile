import 'dart:convert';

import 'package:mmkv/mmkv.dart';

/// MMKV wrapper for simple key-value access and JSON object storage.
///
/// Usage:
/// ```dart
/// await MMKVUtils.instance.init(); // call once before use (e.g. in main)
/// await MMKVUtils.instance.setString('token', 'abc');
/// final token = MMKVUtils.instance.getString('token');
///
/// await MMKVUtils.instance.setObject('user', userMap);
/// final user = MMKVUtils.instance.getObject<Map<String, dynamic>>('user');
/// ```
class MMKVUtils {
  MMKVUtils._();
  static final MMKVUtils instance = MMKVUtils._();

  MMKV? _mmkv;
  final Map<Type, dynamic> _toJsonRegistry = {};
  final Map<Type, dynamic> _fromJsonRegistry = {};

  /// Initialize MMKV. Call once (e.g. in main).
  ///
  /// For mmkv 1.3.16 (synchronous instance creation):
  /// - default instance: MMKV.defaultMMKV()
  /// - custom id: MMKV(id)
  Future<void> init({String? id}) async {
    await MMKV.initialize();
    _mmkv = id == null ? MMKV.defaultMMKV() : MMKV(id);
  }

  MMKV get _store {
    final store = _mmkv;
    if (store == null) {
      throw StateError('MMKV not initialized. Call MMKVUtils.instance.init() first.');
    }
    return store;
  }

  // ---- Basic types ----

  bool setString(String key, String value) => _store.encodeString(key, value);
  String? getString(String key, {String? defaultValue}) => _store.decodeString(key) ?? defaultValue;

  bool setInt(String key, int value) => _store.encodeInt(key, value);
  int? getInt(String key, {int? defaultValue}) => _store.decodeInt(key) ?? defaultValue;

  bool setBool(String key, bool value) => _store.encodeBool(key, value);
  bool? getBool(String key, {bool? defaultValue}) => _store.decodeBool(key) ?? defaultValue;

  bool setDouble(String key, double value) => _store.encodeDouble(key, value);
  double? getDouble(String key, {double? defaultValue}) => _store.decodeDouble(key) ?? defaultValue;

  // ---- Object via JSON ----

  /// Store any JSON-encodable object (Map/List/primitive).
  bool setObject(String key, Object value) {
    final jsonStr = jsonEncode(value);
    return _store.encodeString(key, jsonStr);
  }

  /// Decode JSON object to raw dynamic (Map/List/primitive).
  T? getObject<T>(String key) {
    final jsonStr = _store.decodeString(key);
    if (jsonStr == null) return null;
    final decoded = jsonDecode(jsonStr);
    return decoded as T;
  }

  /// Register converters for a given model type so you don't have to pass
  /// toJson/fromJson every time.
  void registerModelConverter<T>({
    required Map<String, dynamic> Function(T) toJson,
    required T Function(Map<String, dynamic>) fromJson,
  }) {
    _toJsonRegistry[T] = toJson;
    _fromJsonRegistry[T] = fromJson;
  }

  Map<String, dynamic> Function(T) _resolveToJson<T>(
      Map<String, dynamic> Function(T)? toJson) {
    final converter = toJson ?? _toJsonRegistry[T] as Map<String, dynamic> Function(T)?;
    if (converter == null) {
      throw ArgumentError('No toJson converter provided or registered for type $T');
    }
    return converter;
  }

  T Function(Map<String, dynamic>) _resolveFromJson<T>(
      T Function(Map<String, dynamic>)? fromJson) {
    final converter = fromJson ?? _fromJsonRegistry[T] as T Function(Map<String, dynamic>)?;
    if (converter == null) {
      throw ArgumentError('No fromJson converter provided or registered for type $T');
    }
    return converter;
  }

  /// Store a typed model using a toJson converter (passed or registered).
  bool setModel<T>(String key, T value,
      {Map<String, dynamic> Function(T)? toJson}) {
    final encoder = _resolveToJson(toJson);
    final jsonStr = jsonEncode(encoder(value));
    return _store.encodeString(key, jsonStr);
  }

  /// Read a typed model using a fromJson converter (passed or registered).
  T? getModel<T>(String key, {T Function(Map<String, dynamic>)? fromJson}) {
    final decoder = _resolveFromJson(fromJson);
    final jsonStr = _store.decodeString(key);
    if (jsonStr == null) return null;
    final decoded = jsonDecode(jsonStr);
    if (decoded is Map<String, dynamic>) {
      return decoder(decoded);
    }
    if (decoded is Map) {
      return decoder(decoded.map((k, v) => MapEntry(k.toString(), v)));
    }
    return null;
  }

  /// Store a list of typed models.
  bool setModelList<T>(String key, List<T> list,
      {Map<String, dynamic> Function(T)? toJson}) {
    final encoder = _resolveToJson(toJson);
    final jsonStr = jsonEncode(list.map((e) => encoder(e)).toList());
    return _store.encodeString(key, jsonStr);
  }

  /// Read a list of typed models.
  List<T>? getModelList<T>(String key,
      {T Function(Map<String, dynamic>)? fromJson}) {
    final decoder = _resolveFromJson(fromJson);
    final jsonStr = _store.decodeString(key);
    if (jsonStr == null) return null;
    final decoded = jsonDecode(jsonStr);
    if (decoded is List) {
      return decoded
          .whereType<Map>()
          .map((e) => decoder(e.map((k, v) => MapEntry(k.toString(), v))))
          .toList();
    }
    return null;
  }

  // ---- List of strings convenience ----

  bool setStringList(String key, List<String> value) => _store.encodeString(key, jsonEncode(value));
  List<String>? getStringList(String key) {
    final jsonStr = _store.decodeString(key);
    if (jsonStr == null) return null;
    final decoded = jsonDecode(jsonStr);
    if (decoded is List) {
      return decoded.map((e) => e.toString()).toList();
    }
    return null;
  }

  // ---- Utility ----

  bool contains(String key) => _store.containsKey(key);
  void remove(String key) {
    _store.removeValue(key);
  }

  void clear() {
    _store.clearAll();
  }
}

