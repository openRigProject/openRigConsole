import 'package:flutter/material.dart';
import 'package:openrig_core/openrig_core.dart';
import '../services/settings_service.dart';

class PreferencesDialog extends StatefulWidget {
  final SettingsService settings;

  const PreferencesDialog({super.key, required this.settings});

  @override
  State<PreferencesDialog> createState() => _PreferencesDialogState();
}

class _PreferencesDialogState extends State<PreferencesDialog> {
  late final TextEditingController _callsignCtl;
  late final TextEditingController _gridSquareCtl;
  late final TextEditingController _clusterHostCtl;
  late final TextEditingController _clusterPortCtl;
  late final TextEditingController _logPathCtl;
  late final TextEditingController _sidecarPortCtl;
  late final TextEditingController _qrzApiKeyCtl;
  late final TextEditingController _qrzXmlUserCtl;
  late final TextEditingController _qrzXmlPassCtl;
  String? _gridError;
  bool _verifyingKey = false;
  bool _verifyingXml = false;

  SettingsService get _s => widget.settings;

  @override
  void initState() {
    super.initState();
    _callsignCtl = TextEditingController(text: _s.callsign);
    _gridSquareCtl = TextEditingController(text: _s.gridSquare);
    _clusterHostCtl = TextEditingController(text: _s.clusterHost);
    _clusterPortCtl = TextEditingController(text: _s.clusterPort.toString());
    _logPathCtl = TextEditingController(text: _s.logPath);
    _sidecarPortCtl = TextEditingController(text: _s.sidecarPort.toString());
    _qrzApiKeyCtl = TextEditingController(text: _s.qrzApiKey);
    _qrzXmlUserCtl = TextEditingController(text: _s.qrzXmlUser);
    _qrzXmlPassCtl = TextEditingController(text: _s.qrzXmlPass);
  }

  @override
  void dispose() {
    _callsignCtl.dispose();
    _gridSquareCtl.dispose();
    _clusterHostCtl.dispose();
    _clusterPortCtl.dispose();
    _logPathCtl.dispose();
    _sidecarPortCtl.dispose();
    _qrzApiKeyCtl.dispose();
    _qrzXmlUserCtl.dispose();
    _qrzXmlPassCtl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    await _s.setCallsign(_callsignCtl.text.trim().toUpperCase());
    await _s.setGridSquare(_gridSquareCtl.text.trim().toUpperCase());
    await _s.setQrzApiKey(_qrzApiKeyCtl.text.trim());
    await _s.setQrzXmlCredentials(
      _qrzXmlUserCtl.text.trim(),
      _qrzXmlPassCtl.text.trim(),
    );
    await _s.setClusterNode(
      _clusterHostCtl.text.trim(),
      int.tryParse(_clusterPortCtl.text.trim()) ?? 23,
    );
    await _s.setLogPath(_logPathCtl.text.trim());
    await _s.setSidecarPort(
      int.tryParse(_sidecarPortCtl.text.trim()) ?? 4532,
    );
    if (mounted) Navigator.of(context).pop(true);
  }

  Future<void> _verifyQrzKey() async {
    final key = _qrzApiKeyCtl.text.trim();
    if (key.isEmpty) return;
    setState(() => _verifyingKey = true);
    try {
      final client = QrzLogbookClient(apiKey: key);
      final callsign = await client.checkKey();
      client.dispose();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Verified: $callsign')),
        );
      }
    } on QrzException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Invalid key: ${e.message}')),
        );
      }
    } finally {
      if (mounted) setState(() => _verifyingKey = false);
    }
  }

  Future<void> _verifyQrzXml() async {
    final user = _qrzXmlUserCtl.text.trim();
    final pass = _qrzXmlPassCtl.text.trim();
    if (user.isEmpty || pass.isEmpty) return;
    setState(() => _verifyingXml = true);
    try {
      final client = QrzXmlClient(username: user, password: pass);
      final info = await client.lookupCallsign(user.toUpperCase());
      client.dispose();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Verified: ${info.call} — ${info.fullName}')),
        );
      }
    } on QrzXmlException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('QRZ XML error: ${e.message}')),
        );
      }
    } finally {
      if (mounted) setState(() => _verifyingXml = false);
    }
  }

  Future<void> _forgetLastDevice() async {
    await _s.clearLastDevice();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Saved device cleared')),
      );
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final lastHost = _s.lastHost;

    return AlertDialog(
      title: const Text('Preferences'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // -- Operator --
              _SectionHeader('Operator'),
              TextField(
                controller: _callsignCtl,
                decoration: const InputDecoration(labelText: 'Callsign'),
                textCapitalization: TextCapitalization.characters,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _gridSquareCtl,
                decoration: InputDecoration(
                  labelText: 'Grid Square',
                  hintText: 'e.g. FN31',
                  errorText: _gridError,
                ),
                textCapitalization: TextCapitalization.characters,
                onChanged: (v) {
                  final trimmed = v.trim();
                  setState(() {
                    _gridError = trimmed.isNotEmpty && !isValidGrid(trimmed)
                        ? 'Invalid grid square'
                        : null;
                  });
                },
              ),
              const SizedBox(height: 20),

              // -- DX Cluster --
              _SectionHeader('DX Cluster'),
              Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: TextField(
                      controller: _clusterHostCtl,
                      decoration: const InputDecoration(labelText: 'Host'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _clusterPortCtl,
                      decoration: const InputDecoration(labelText: 'Port'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),

              // -- Log --
              _SectionHeader('Log'),
              TextField(
                controller: _logPathCtl,
                decoration: const InputDecoration(
                  labelText: 'ADIF log file path',
                  hintText: '~/openrig.adi',
                ),
              ),
              const SizedBox(height: 20),

              // -- QRZ Logbook --
              _SectionHeader('QRZ Logbook'),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _qrzApiKeyCtl,
                      decoration: const InputDecoration(
                        labelText: 'API Key',
                        hintText: 'Paste your QRZ.com API key',
                      ),
                      obscureText: true,
                    ),
                  ),
                  const SizedBox(width: 12),
                  _verifyingKey
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : OutlinedButton(
                          onPressed: _verifyQrzKey,
                          child: const Text('Verify Key'),
                        ),
                ],
              ),
              const SizedBox(height: 20),

              // -- QRZ XML Lookup --
              _SectionHeader('QRZ Callsign Lookup'),
              Text(
                'Requires a QRZ.com XML subscription (separate from the Logbook API key).',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _qrzXmlUserCtl,
                decoration: const InputDecoration(labelText: 'QRZ Username'),
                textCapitalization: TextCapitalization.characters,
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _qrzXmlPassCtl,
                      decoration: const InputDecoration(labelText: 'QRZ Password'),
                      obscureText: true,
                    ),
                  ),
                  const SizedBox(width: 12),
                  _verifyingXml
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : OutlinedButton(
                          onPressed: _verifyQrzXml,
                          child: const Text('Verify'),
                        ),
                ],
              ),
              const SizedBox(height: 20),

              // -- Connection --
              _SectionHeader('Connection'),
              Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: TextField(
                      controller: _sidecarPortCtl,
                      decoration: const InputDecoration(
                        labelText: 'Sidecar rigctld port',
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Spacer(),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Text(
                    lastHost != null
                        ? 'Last device: $lastHost:${_s.lastPort}'
                        : 'No saved device',
                    style: TextStyle(
                      fontSize: 13,
                      color: Colors.grey.shade400,
                    ),
                  ),
                  const Spacer(),
                  if (lastHost != null)
                    TextButton(
                      onPressed: _forgetLastDevice,
                      child: const Text('Forget'),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _save,
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader(this.title);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.bold,
          color: Colors.green.shade300,
        ),
      ),
    );
  }
}
