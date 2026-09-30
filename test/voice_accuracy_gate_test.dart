import 'package:flutter_test/flutter_test.dart';

import '../lib/voice_accuracy_gate.dart';
import '../lib/voice_nlp_engine.dart';

ParsedItemV2 item({
  required double confidence,
  String name = 'Tata Salt',
  double qty = 1,
  String unit = 'kg',
  double price = 30,
  String? catalogMatchName = 'Tata Salt',
}) {
  return ParsedItemV2(
    name: name,
    qty: qty,
    unit: unit,
    price: price,
    catalogMatchName: catalogMatchName,
    confidence: ConfidenceDetail(
      nameScore: confidence,
      qtyScore: confidence,
      priceScore: confidence,
      patternBonus: 0.10,
      catalogBonus: 0.15,
    ),
  );
}

void main() {
  final catalog = <Map<String, dynamic>>[
    {'name': 'Tata Salt', 'price': 30, 'unit': 'kg'},
    {'name': 'Aashirvaad Salt', 'price': 32, 'unit': 'kg'},
    {'name': 'Sugar', 'price': 50, 'unit': 'kg'},
  ];

  group('VoiceAccuracyGate', () {
    test('auto-accepts a high-confidence deterministic catalog match', () {
      final result = VoiceAccuracyGate.evaluate(
        item(confidence: 0.95),
        catalog: catalog,
      );

      expect(result.decision, VoiceGateDecision.autoAccept);
      expect(result.isAccepted, isTrue);
    });

    test('requires confirmation for an ambiguous product', () {
      final result = VoiceAccuracyGate.evaluate(
        item(
          confidence: 0.95,
          name: 'Salt',
          catalogMatchName: null,
        ),
        catalog: catalog,
      );

      expect(result.decision, VoiceGateDecision.requiresConfirmation);
      expect(
        result.reasons.map((r) => r.code),
        contains('AMBIGUOUS_PRODUCT'),
      );
    });

    test('rejects low-confidence NLP output', () {
      final result = VoiceAccuracyGate.evaluate(
        item(
          confidence: 0.50,
          name: 'Unknown Product',
          catalogMatchName: null,
        ),
        catalog: catalog,
      );

      expect(result.decision, VoiceGateDecision.reject);
      expect(
        result.reasons.map((r) => r.code),
        contains('LOW_CONFIDENCE'),
      );
    });

    test('never auto-accepts without a catalog', () {
      final result = VoiceAccuracyGate.evaluate(
        item(confidence: 0.99),
        catalog: const [],
      );

      expect(result.decision, VoiceGateDecision.requiresConfirmation);
      expect(
        result.reasons.map((r) => r.code),
        contains('NO_CATALOG'),
      );
    });

    test('rejects invalid quantity', () {
      final result = VoiceAccuracyGate.evaluate(
        item(confidence: 0.99, qty: 0),
        catalog: catalog,
      );

      expect(result.decision, VoiceGateDecision.reject);
      expect(
        result.reasons.map((r) => r.code),
        contains('INVALID_QUANTITY'),
      );
    });

    test('manual validation accepts valid billing fields', () {
      final errors = VoiceAccuracyGate.validateManualFields(
        name: 'Tata Salt',
        qty: 2,
        price: 60,
        unit: 'kg',
      );

      expect(errors, isEmpty);
    });

    test('manual validation rejects unsupported units', () {
      final errors = VoiceAccuracyGate.validateManualFields(
        name: 'Tata Salt',
        qty: 2,
        price: 60,
        unit: 'unknown_unit',
      );

      expect(
        errors.map((r) => r.code),
        contains('INVALID_UNIT'),
      );
    });
  });
}
