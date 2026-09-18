import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Builds the single hardened [FlutterSecureStorage] used for every secret
/// the app persists (GitHub token, API keys, MCP env, SSH keys, passwords).
///
/// `flutter_secure_storage` 9.x defaults to unauthenticated AES-CBC
/// (`AES_CBC_PKCS7Padding`) and RSA-ECB/PKCS#1, and leaves
/// `encryptedSharedPreferences` disabled. This factory opts into:
/// - `encryptedSharedPreferences: true` — values live in Android's
///   Keystore-backed EncryptedSharedPreferences (API 23+, our minSdk).
/// - `AES_GCM_NoPadding` — authenticated encryption for stored values.
/// - `RSA_ECB_OAEPwithSHA_256andMGF1Padding` — OAEP key wrapping for the
///   stored data key.
/// - `resetOnError: false` — a decryption failure never silently wipes
///   the user's secrets.
FlutterSecureStorage ovidSecureStorage() => const FlutterSecureStorage(
      aOptions: AndroidOptions(
        encryptedSharedPreferences: true,
        resetOnError: false,
        keyCipherAlgorithm:
            KeyCipherAlgorithm.RSA_ECB_OAEPwithSHA_256andMGF1Padding,
        storageCipherAlgorithm: StorageCipherAlgorithm.AES_GCM_NoPadding,
      ),
    );
