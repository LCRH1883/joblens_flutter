import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _kEmailAuthRedirectUri = 'joblens://auth-callback';

class AuthPage extends StatefulWidget {
  const AuthPage({super.key});

  @override
  State<AuthPage> createState() => _AuthPageState();
}

class _AuthPageState extends State<AuthPage> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  bool _isSignIn = true;
  bool _isSubmitting = false;
  bool _obscurePassword = true;
  String? _statusMessage;
  String? _errorMessage;
  String? _pendingConfirmationEmail;
  late final StreamSubscription<AuthState> _authSubscription;

  @override
  void initState() {
    super.initState();
    _authSubscription = Supabase.instance.client.auth.onAuthStateChange.listen((
      state,
    ) {
      if (!mounted || state.session?.user == null) {
        return;
      }
      if (state.event == AuthChangeEvent.passwordRecovery) {
        return;
      }
      Navigator.of(context).maybePop(true);
    });
  }

  @override
  void dispose() {
    _authSubscription.cancel();
    _emailController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(
          _pendingConfirmationEmail != null
              ? 'Confirm email'
              : _isSignIn
              ? 'Sign in'
              : 'Create account',
        ),
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: _pendingConfirmationEmail != null
                  ? _buildConfirmationPending(theme)
                  : Form(
                      key: _formKey,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            'Joblens',
                            style: theme.textTheme.displaySmall?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            _isSignIn
                                ? 'Sign in to sync Joblens with your cloud storage.'
                                : 'Create your Joblens account to start syncing.',
                            style: theme.textTheme.bodyLarge,
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 24),
                          if (_errorMessage != null) ...[
                            _MessageCard(
                              message: _errorMessage!,
                              backgroundColor: theme.colorScheme.errorContainer,
                              foregroundColor:
                                  theme.colorScheme.onErrorContainer,
                            ),
                            const SizedBox(height: 12),
                          ],
                          if (_statusMessage != null) ...[
                            _MessageCard(
                              message: _statusMessage!,
                              backgroundColor:
                                  theme.colorScheme.primaryContainer,
                              foregroundColor:
                                  theme.colorScheme.onPrimaryContainer,
                            ),
                            const SizedBox(height: 12),
                          ],
                          TextFormField(
                            controller: _emailController,
                            keyboardType: TextInputType.emailAddress,
                            autofillHints: const [AutofillHints.email],
                            decoration: const InputDecoration(
                              labelText: 'Email',
                              border: OutlineInputBorder(),
                            ),
                            validator: (value) {
                              final email = value?.trim() ?? '';
                              if (email.isEmpty) {
                                return 'Enter your email.';
                              }
                              if (!email.contains('@')) {
                                return 'Enter a valid email.';
                              }
                              return null;
                            },
                          ),
                          const SizedBox(height: 12),
                          TextFormField(
                            controller: _passwordController,
                            obscureText: _obscurePassword,
                            autofillHints: _isSignIn
                                ? const [AutofillHints.password]
                                : const [AutofillHints.newPassword],
                            decoration: InputDecoration(
                              labelText: 'Password',
                              border: const OutlineInputBorder(),
                              suffixIcon: IconButton(
                                onPressed: () {
                                  setState(() {
                                    _obscurePassword = !_obscurePassword;
                                  });
                                },
                                icon: Icon(
                                  _obscurePassword
                                      ? Icons.visibility_outlined
                                      : Icons.visibility_off_outlined,
                                ),
                              ),
                            ),
                            validator: (value) {
                              final password = value ?? '';
                              if (password.isEmpty) {
                                return 'Enter your password.';
                              }
                              if (!_isSignIn && password.length < 8) {
                                return 'Password must be at least 8 characters.';
                              }
                              return null;
                            },
                          ),
                          if (!_isSignIn) ...[
                            const SizedBox(height: 12),
                            TextFormField(
                              controller: _confirmPasswordController,
                              obscureText: _obscurePassword,
                              autofillHints: const [AutofillHints.newPassword],
                              decoration: const InputDecoration(
                                labelText: 'Confirm password',
                                border: OutlineInputBorder(),
                              ),
                              validator: (value) {
                                if ((value ?? '') != _passwordController.text) {
                                  return 'Passwords do not match.';
                                }
                                return null;
                              },
                            ),
                          ],
                          const SizedBox(height: 16),
                          FilledButton(
                            onPressed: _isSubmitting ? null : _submit,
                            child: Text(
                              _isSignIn ? 'Sign in' : 'Create account',
                            ),
                          ),
                          if (_isSignIn) ...[
                            const SizedBox(height: 8),
                            Align(
                              alignment: Alignment.centerRight,
                              child: TextButton(
                                onPressed: _isSubmitting
                                    ? null
                                    : _showForgotPasswordDialog,
                                child: const Text('Forgot password?'),
                              ),
                            ),
                          ],
                          const SizedBox(height: 12),
                          TextButton(
                            onPressed: _isSubmitting ? null : _toggleMode,
                            child: Text(
                              _isSignIn
                                  ? 'Need an account? Create one'
                                  : 'Already have an account? Sign in',
                            ),
                          ),
                        ],
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildConfirmationPending(ThemeData theme) {
    final email = _pendingConfirmationEmail!;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Icon(
          Icons.mark_email_read_outlined,
          size: 64,
          color: theme.colorScheme.primary,
        ),
        const SizedBox(height: 16),
        Text(
          'Confirm your email',
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w700,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 12),
        Text(
          'We sent a confirmation link to $email. Open that link on this device to finish signing in to Joblens.',
          style: theme.textTheme.bodyLarge,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 24),
        if (_errorMessage != null) ...[
          _MessageCard(
            message: _errorMessage!,
            backgroundColor: theme.colorScheme.errorContainer,
            foregroundColor: theme.colorScheme.onErrorContainer,
          ),
          const SizedBox(height: 12),
        ],
        if (_statusMessage != null) ...[
          _MessageCard(
            message: _statusMessage!,
            backgroundColor: theme.colorScheme.primaryContainer,
            foregroundColor: theme.colorScheme.onPrimaryContainer,
          ),
          const SizedBox(height: 12),
        ],
        FilledButton(
          onPressed: _isSubmitting ? null : _resendConfirmationEmail,
          child: const Text('Resend confirmation email'),
        ),
        const SizedBox(height: 12),
        TextButton(
          onPressed: _isSubmitting ? null : _returnToSignIn,
          child: const Text('Back to sign in'),
        ),
      ],
    );
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    setState(() {
      _isSubmitting = true;
      _errorMessage = null;
      _statusMessage = null;
      _pendingConfirmationEmail = null;
    });

    final auth = Supabase.instance.client.auth;
    final email = _emailController.text.trim();
    final password = _passwordController.text;

    try {
      if (_isSignIn) {
        await auth.signInWithPassword(email: email, password: password);
      } else {
        final response = await auth.signUp(
          email: email,
          password: password,
          emailRedirectTo: _kEmailAuthRedirectUri,
        );
        if (!mounted) {
          return;
        }
        setState(() {
          if (response.session == null) {
            _pendingConfirmationEmail = email;
            _statusMessage =
                'Account created. Check your email to confirm this device.';
          } else {
            _statusMessage = 'Account created. You are now signed in.';
          }
        });
      }
    } on AuthException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        if (_looksLikeUnconfirmedEmailError(error.message)) {
          _pendingConfirmationEmail = email;
          _statusMessage =
              'Your email is not confirmed yet. Open the confirmation link we sent to $email.';
          return;
        }
        _errorMessage = error.message;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _errorMessage = _friendlyAuthError(error);
      });
    } finally {
      if (mounted) {
        setState(() {
          _isSubmitting = false;
        });
      }
    }
  }

  Future<void> _resendConfirmationEmail() async {
    final email = _pendingConfirmationEmail;
    if (email == null || email.isEmpty) {
      return;
    }

    setState(() {
      _isSubmitting = true;
      _errorMessage = null;
      _statusMessage = null;
    });

    try {
      await Supabase.instance.client.auth.resend(
        email: email,
        type: OtpType.signup,
        emailRedirectTo: _kEmailAuthRedirectUri,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _statusMessage = 'Confirmation email resent to $email.';
      });
    } on AuthException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _errorMessage = error.message;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _errorMessage = _friendlyAuthError(error);
      });
    } finally {
      if (mounted) {
        setState(() {
          _isSubmitting = false;
        });
      }
    }
  }

  Future<void> _showForgotPasswordDialog() async {
    final controller = TextEditingController(
      text: _emailController.text.trim(),
    );
    String? validationMessage;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('Reset password'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Enter your email and Joblens will send you a password reset link.',
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: controller,
                    keyboardType: TextInputType.emailAddress,
                    autofocus: true,
                    decoration: InputDecoration(
                      labelText: 'Email',
                      border: const OutlineInputBorder(),
                      errorText: validationMessage,
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: _isSubmitting
                      ? null
                      : () => Navigator.of(dialogContext).pop(),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: _isSubmitting
                      ? null
                      : () async {
                          final email = controller.text.trim();
                          final errorMessage = _validateEmail(email);
                          if (errorMessage != null) {
                            setDialogState(() {
                              validationMessage = errorMessage;
                            });
                            return;
                          }
                          Navigator.of(dialogContext).pop();
                          await _sendPasswordResetEmail(email);
                        },
                  child: const Text('Send link'),
                ),
              ],
            );
          },
        );
      },
    );

    controller.dispose();
  }

  Future<void> _sendPasswordResetEmail(String email) async {
    setState(() {
      _isSubmitting = true;
      _errorMessage = null;
      _statusMessage = null;
    });

    try {
      await Supabase.instance.client.auth.resetPasswordForEmail(
        email,
        redirectTo: _kEmailAuthRedirectUri,
      );
      if (!mounted) {
        return;
      }
      _emailController.text = email;
      setState(() {
        _statusMessage = 'Password reset link sent to $email.';
      });
    } on AuthException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _errorMessage = error.message;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _errorMessage = _friendlyAuthError(error);
      });
    } finally {
      if (mounted) {
        setState(() {
          _isSubmitting = false;
        });
      }
    }
  }

  void _returnToSignIn() {
    setState(() {
      _isSignIn = true;
      _pendingConfirmationEmail = null;
      _errorMessage = null;
      _statusMessage = null;
      _confirmPasswordController.clear();
    });
  }

  void _toggleMode() {
    setState(() {
      _isSignIn = !_isSignIn;
      _pendingConfirmationEmail = null;
      _errorMessage = null;
      _statusMessage = null;
      _confirmPasswordController.clear();
    });
  }

  bool _looksLikeUnconfirmedEmailError(String message) {
    final normalized = message.toLowerCase();
    return normalized.contains('email not confirmed') ||
        normalized.contains('email is not confirmed');
  }

  String? _validateEmail(String value) {
    final email = value.trim();
    if (email.isEmpty) {
      return 'Enter your email.';
    }
    if (!email.contains('@')) {
      return 'Enter a valid email.';
    }
    return null;
  }

  String _friendlyAuthError(Object error) {
    final message = error.toString().toLowerCase();
    if (message.contains('socketexception') ||
        message.contains('clientexception') ||
        message.contains('failed host lookup') ||
        message.contains('timed out') ||
        message.contains('connection refused')) {
      return 'Joblens cannot reach sign-in right now. You can keep using the app offline and try again later.';
    }
    return 'Something went wrong. Please try again.';
  }
}

class _MessageCard extends StatelessWidget {
  const _MessageCard({
    required this.message,
    required this.backgroundColor,
    required this.foregroundColor,
  });

  final String message;
  final Color backgroundColor;
  final Color foregroundColor;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: backgroundColor,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Text(
          message,
          style: TextStyle(color: foregroundColor),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}
