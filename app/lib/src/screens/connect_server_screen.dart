import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../theme.dart';

class ConnectServerScreen extends StatefulWidget {
  const ConnectServerScreen({required this.controller, super.key});

  final AppController controller;

  @override
  State<ConnectServerScreen> createState() => _ConnectServerScreenState();
}

class _ConnectServerScreenState extends State<ConnectServerScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController(text: 'My server');
  final _urlController = TextEditingController(text: 'https://');
  final _tokenController = TextEditingController();
  bool _obscureToken = true;

  @override
  void dispose() {
    _nameController.dispose();
    _urlController.dispose();
    _tokenController.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }
    await widget.controller.connect(
      name: _nameController.text,
      serverUrl: _urlController.text,
      token: _tokenController.text,
    );
  }

  @override
  Widget build(BuildContext context) {
    final isConnecting = widget.controller.phase == ConnectionPhase.connecting;
    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 900;
            return Row(
              children: [
                if (wide) const Expanded(child: _WelcomePanel()),
                Expanded(
                  child: Center(
                    child: SingleChildScrollView(
                      padding: EdgeInsets.symmetric(
                        horizontal: wide ? 64 : 24,
                        vertical: 32,
                      ),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 480),
                        child: Form(
                          key: _formKey,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              if (!wide) ...[
                                const _Brand(),
                                const SizedBox(height: 40),
                              ],
                              Text(
                                'Connect your Linux server',
                                style: Theme.of(context)
                                    .textTheme
                                    .headlineLarge,
                              ),
                              const SizedBox(height: 12),
                              Text(
                                'Start with a Linux server or VPS that you already own. '
                                'EasyPrivacy will read its real health and storage status.',
                                style: Theme.of(context).textTheme.bodyLarge
                                    ?.copyWith(color: easyPrivacyMuted),
                              ),
                              const SizedBox(height: 32),
                              TextFormField(
                                controller: _nameController,
                                textInputAction: TextInputAction.next,
                                decoration: const InputDecoration(
                                  labelText: 'Server name',
                                  hintText: 'Home server',
                                ),
                                validator: (value) =>
                                    value == null || value.trim().isEmpty
                                    ? 'Enter a name for this server.'
                                    : null,
                              ),
                              const SizedBox(height: 16),
                              TextFormField(
                                key: const Key('server-url-field'),
                                controller: _urlController,
                                keyboardType: TextInputType.url,
                                autocorrect: false,
                                textInputAction: TextInputAction.next,
                                decoration: const InputDecoration(
                                  labelText: 'Agent address',
                                  hintText: 'https://server.example.com:7443',
                                ),
                                validator: (value) =>
                                    value == null || value.trim().isEmpty
                                    ? 'Enter the EasyPrivacy agent address.'
                                    : null,
                              ),
                              const SizedBox(height: 16),
                              TextFormField(
                                key: const Key('device-token-field'),
                                controller: _tokenController,
                                obscureText: _obscureToken,
                                autocorrect: false,
                                enableSuggestions: false,
                                onFieldSubmitted: (_) =>
                                    isConnecting ? null : _connect(),
                                decoration: InputDecoration(
                                  labelText: 'Development agent token',
                                  suffixIcon: IconButton(
                                    tooltip: _obscureToken
                                        ? 'Show token'
                                        : 'Hide token',
                                    onPressed: () => setState(
                                      () => _obscureToken = !_obscureToken,
                                    ),
                                    icon: Icon(
                                      _obscureToken
                                          ? Icons.visibility_outlined
                                          : Icons.visibility_off_outlined,
                                    ),
                                  ),
                                ),
                                validator: (value) =>
                                    value == null || value.trim().isEmpty
                                    ? 'Enter the device token generated by your server.'
                                    : null,
                              ),
                              if (widget.controller.errorMessage != null) ...[
                                const SizedBox(height: 16),
                                _ErrorNotice(
                                  message: widget.controller.errorMessage!,
                                ),
                              ],
                              const SizedBox(height: 24),
                              FilledButton.icon(
                                key: const Key('connect-button'),
                                onPressed: isConnecting ? null : _connect,
                                icon: isConnecting
                                    ? const SizedBox.square(
                                        dimension: 18,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : const Icon(Icons.link_rounded),
                                label: Text(
                                  isConnecting
                                      ? 'Connecting…'
                                      : 'Connect server',
                                ),
                              ),
                              const SizedBox(height: 12),
                              OutlinedButton.icon(
                                key: const Key('demo-button'),
                                onPressed: isConnecting
                                    ? null
                                    : widget.controller.openDemo,
                                icon: const Icon(
                                  Icons.play_circle_outline_rounded,
                                ),
                                label: const Text('Explore the demo dashboard'),
                              ),
                              const SizedBox(height: 24),
                              const _SecurityNote(),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _WelcomePanel extends StatelessWidget {
  const _WelcomePanel();

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: const Color(0xFFF0F7F1),
      child: Padding(
        padding: const EdgeInsets.all(64),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _Brand(),
            const Spacer(),
            Container(
              width: 74,
              height: 74,
              decoration: const BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
              ),
              padding: const EdgeInsets.all(15),
              child: Image.asset('assets/easyprivacy-mark.png'),
            ),
            const SizedBox(height: 28),
            Text(
              'Your infrastructure.\nYour credentials.\nYour data.',
              style: Theme.of(context).textTheme.headlineLarge
                  ?.copyWith(fontSize: 46),
            ),
            const SizedBox(height: 20),
            Text(
              'EasyPrivacy helps configure and operate services on hardware and '
              'accounts you control.',
              style: Theme.of(context).textTheme.bodyLarge
                  ?.copyWith(color: easyPrivacyMuted),
            ),
            const Spacer(),
            const Text(
              'Version 0.1 · Existing Linux server path',
              style: TextStyle(color: easyPrivacyMuted),
            ),
          ],
        ),
      ),
    );
  }
}

class _Brand extends StatelessWidget {
  const _Brand();

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox.square(
          dimension: 44,
          child: Image.asset('assets/easyprivacy-mark.png'),
        ),
        const SizedBox(width: 12),
        Text('EasyPrivacy', style: Theme.of(context).textTheme.titleLarge),
      ],
    );
  }
}

class _SecurityNote extends StatelessWidget {
  const _SecurityNote();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: easyPrivacySoftGreen,
        borderRadius: BorderRadius.circular(12),
      ),
      child: const Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.shield_outlined, color: easyPrivacyDarkGreen, size: 21),
          SizedBox(width: 12),
          Expanded(
            child: Text(
              'This initial build keeps the token only for the current app session. '
              'Remote connections require HTTPS.',
              style: TextStyle(color: easyPrivacyDarkGreen, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorNotice extends StatelessWidget {
  const _ErrorNotice({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline, color: Theme.of(context).colorScheme.error),
          const SizedBox(width: 10),
          Expanded(child: Text(message)),
        ],
      ),
    );
  }
}
