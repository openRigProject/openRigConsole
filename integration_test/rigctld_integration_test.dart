import 'dart:io';

import 'package:test/test.dart';
import 'package:openrig_core/openrig_core.dart';

/// Integration tests for RigctldClient against a real rigctld process.
///
/// Uses hamlib model 1 (Dummy rig) — no hardware needed, safe for CI.
void main() {
  late Process rigctldProcess;
  late RigctldClient client;
  const port = 14532; // Non-standard port to avoid conflicts

  setUpAll(() async {
    rigctldProcess = await Process.start(
      'rigctld',
      ['-m', '1', '-t', port.toString()],
    );
    // Wait for rigctld to bind the port
    await Future<void>.delayed(const Duration(milliseconds: 500));
  });

  tearDownAll(() {
    rigctldProcess.kill();
  });

  setUp(() async {
    client = RigctldClient(host: 'localhost', port: port);
    await client.connect();
  });

  tearDown(() async {
    await client.disconnect();
  });

  group('frequency', () {
    test('get/set frequency round-trip', () async {
      await client.setFrequency(14225000);
      final freq = await client.getFrequency();
      expect(freq, equals(14225000));
    });

    test('set frequency to different band', () async {
      await client.setFrequency(7074000);
      final freq = await client.getFrequency();
      expect(freq, equals(7074000));
    });
  });

  group('mode', () {
    test('get/set mode round-trip — USB', () async {
      await client.setMode('USB');
      final result = await client.getMode();
      expect(result.mode, equals('USB'));
    });

    test('get/set mode round-trip — CW', () async {
      await client.setMode('CW');
      final result = await client.getMode();
      expect(result.mode, equals('CW'));
    });

    test('get/set mode round-trip — LSB', () async {
      await client.setMode('LSB');
      final result = await client.getMode();
      expect(result.mode, equals('LSB'));
    });

    test('get/set mode round-trip — FM', () async {
      await client.setMode('FM');
      final result = await client.getMode();
      expect(result.mode, equals('FM'));
    });

    test('get/set mode round-trip — AM', () async {
      await client.setMode('AM');
      final result = await client.getMode();
      expect(result.mode, equals('AM'));
    });
  });

  group('PTT', () {
    test('get/set PTT on', () async {
      await client.setPtt(true);
      final ptt = await client.getPtt();
      expect(ptt, isTrue);
    });

    test('get/set PTT off', () async {
      // Ensure PTT is on first, then turn off
      await client.setPtt(true);
      await client.setPtt(false);
      final ptt = await client.getPtt();
      expect(ptt, isFalse);
    });

    test('PTT round-trip toggle', () async {
      await client.setPtt(false);
      expect(await client.getPtt(), isFalse);

      await client.setPtt(true);
      expect(await client.getPtt(), isTrue);

      await client.setPtt(false);
      expect(await client.getPtt(), isFalse);
    });
  });

  group('combined operations', () {
    test('set frequency, mode, and PTT together', () async {
      await client.setFrequency(21295000);
      await client.setMode('USB');
      await client.setPtt(true);

      expect(await client.getFrequency(), equals(21295000));
      final mode = await client.getMode();
      expect(mode.mode, equals('USB'));
      expect(await client.getPtt(), isTrue);

      await client.setPtt(false);
      expect(await client.getPtt(), isFalse);
    });
  });
}
