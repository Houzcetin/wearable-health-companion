import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/env.dart';

class AppUser {
  const AppUser({required this.id, this.email});
  final String id;
  final String? email;
}

class UserFacingException implements Exception {
  const UserFacingException(this.message);
  final String message;
  @override
  String toString() => message;
}

abstract class AuthRepository {
  AppUser? get currentUser;
  Stream<AppUser?> get authStateChanges;
  Future<void> signInWithGoogle();
  Future<void> signOut();
}

class SupabaseAuthRepository implements AuthRepository {
  SupabaseAuthRepository(this._client);
  final SupabaseClient? _client;
  static Future<void>? _googleInitialization;

  AppUser? _user(User? user) =>
      user == null ? null : AppUser(id: user.id, email: user.email);

  @override
  AppUser? get currentUser => _user(_client?.auth.currentUser);

  @override
  Stream<AppUser?> get authStateChanges async* {
    yield currentUser;
    final client = _client;
    if (client != null) {
      yield* client.auth.onAuthStateChange.map(
        (event) => _user(event.session?.user),
      );
    }
  }

  @override
  Future<void> signInWithGoogle() async {
    final client = _client;
    if (client == null) {
      throw const UserFacingException('Backend not configured.');
    }
    if (kIsWeb ||
        (defaultTargetPlatform != TargetPlatform.android &&
            defaultTargetPlatform != TargetPlatform.iOS)) {
      throw const UserFacingException(
        'Google sign-in is available on Android and iOS.',
      );
    }
    if (Env.googleWebClientId.isEmpty ||
        (defaultTargetPlatform == TargetPlatform.iOS &&
            Env.googleIosClientId.isEmpty)) {
      throw const UserFacingException(
        'Google sign-in has not been configured for this app.',
      );
    }
    try {
      final google = GoogleSignIn.instance;
      await (_googleInitialization ??= google.initialize(
        serverClientId: Env.googleWebClientId,
        clientId: defaultTargetPlatform == TargetPlatform.iOS
            ? Env.googleIosClientId
            : null,
      ));
      final account = await google.authenticate();
      final idToken = account.authentication.idToken;
      if (idToken == null) {
        throw const UserFacingException(
          'Google returned no identity token. Please try again.',
        );
      }
      // Identity only. Health scopes are requested later by health-oauth-start.
      const scopes = ['email', 'profile'];
      final authorization =
          await account.authorizationClient.authorizationForScopes(scopes) ??
          await account.authorizationClient.authorizeScopes(scopes);

      // Native Google flow prescribed by Supabase and google_sign_in 7.
      // Do not invent a nonce from the returned JWT or weaken server validation.
      // Supabase's iOS setup currently requires Skip nonce check; the project's
      // strict setting must be verified on a device. See docs/SETUP.md.
      await client.auth.signInWithIdToken(
        provider: OAuthProvider.google,
        idToken: idToken,
        accessToken: authorization.accessToken,
      );
    } on GoogleSignInException catch (error) {
      if (error.code == GoogleSignInExceptionCode.canceled) {
        throw const UserFacingException(
          'Sign-in was cancelled. You can try again when ready.',
        );
      }
      throw const UserFacingException(
        'Google sign-in failed. Check your connection and try again.',
      );
    } on AuthException catch (error) {
      if (error.message.toLowerCase().contains('nonce')) {
        throw const UserFacingException(
          'Google sign-in could not be verified. The app’s sign-in configuration needs attention.',
        );
      }
      throw const UserFacingException('Could not sign in. Please try again.');
    }
  }

  @override
  Future<void> signOut() async {
    await _client?.auth.signOut();
    if (_googleInitialization != null) {
      // Supabase sign-out is authoritative; Google cleanup must not keep the
      // account signed into this app if a platform cleanup call fails.
      try {
        await GoogleSignIn.instance.signOut();
      } catch (_) {
        // The Supabase session has already been cleared.
      }
    }
  }
}
