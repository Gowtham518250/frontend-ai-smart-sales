import 'voice_nlp_engine.dart';

/// Decision returned by the production voice-billing safety gate.
enum VoiceGateDecision {
  autoAccept,
  requiresConfirmation,
  reject,
}

/// Machine-readable reason attached to every gated result.
class VoiceGateReason {
  final String code;
  final String message;

  const VoiceGateReason(this.code, this.message);

  @override
  String toString() => '$code: $message';
}

/// Result of validating one parsed voice-billing item.
class VoiceGateResult {
  final VoiceGateDecision decision;
  final List<VoiceGateReason> reasons;

  const VoiceGateResult({
    required this.decision,
    this.reasons = const [],
  });

  bool get isAccepted => decision == VoiceGateDecision.autoAccept;
  bool get requiresConfirmation =>
      decision == VoiceGateDecision.requiresConfirmation;
  bool get isRejected => decision == VoiceGateDecision.reject;

  String get summary =>
      reasons.isEmpty ? 'Validated' : reasons.map((r) => r.message).join(' ');
}

/// Production safety/accuracy layer between NLP output and billing.
///
/// The NLP engine is intentionally permissive so it can recover imperfect STT.
/// This gate is intentionally conservative so uncertain NLP output cannot become
/// a financial mutation without user confirmation.
class VoiceAccuracyGate {
  VoiceAccuracyGate._();

  static const double autoAcceptThreshold = 0.90;
  static const double confirmationThreshold = 0.72;

  static const Set<String> _supportedUnits = {
    'kg',
    'g',
    'mg',
    'l',
    'ml',
    'pc',
    'pack',
    'packet',
    'box',
    'bottle',
    'jar',
    'tin',
    'bag',
    'sachet',
    'pouch',
    'tube',
    'dozen',
  };

  static const Set<String> _invalidNames = {
    'a',
    'an',
    'the',
    'and',
    'or',
    'in',
    'at',
    'on',
    'of',
    'to',
    'price',
    'cost',
    'amount',
    'total',
    'rupee',
    'rupees',
    'rs',
    'inr',
  };

  static VoiceGateResult evaluate(
    ParsedItemV2 item, {
    List<Map<String, dynamic>>? catalog,
  }) {
    final reasons = <VoiceGateReason>[];

    final structural = validateManualFields(
      name: item.name,
      qty: item.qty,
      price: item.price,
      unit: item.unit,
    );
    reasons.addAll(structural);

    if (reasons.isNotEmpty) {
      return VoiceGateResult(
        decision: VoiceGateDecision.reject,
        reasons: reasons,
      );
    }

    final confidence = item.confidenceScore;
    if (confidence < confirmationThreshold) {
      reasons.add(const VoiceGateReason(
        'LOW_CONFIDENCE',
        'Voice interpretation is below the safe confidence threshold.',
      ));
      return VoiceGateResult(
        decision: VoiceGateDecision.reject,
        reasons: reasons,
      );
    }

    final hasCatalog = catalog != null && catalog.isNotEmpty;
    final exactMatches = hasCatalog
        ? _exactCatalogMatches(item.name, catalog!)
        : <Map<String, dynamic>>[];

    final ambiguity = hasCatalog
        ? _findCatalogAmbiguity(item.name, catalog!)
        : const _Ambiguity.none();

    if (ambiguity.isAmbiguous && exactMatches.length != 1) {
      reasons.add(const VoiceGateReason(
        'AMBIGUOUS_PRODUCT',
        'Multiple catalog products are similarly matched. Confirm the product before billing.',
      ));
      if (ambiguity.topName != null && ambiguity.secondName != null) {
        reasons.add(
          VoiceGateReason(
            'AMBIGUOUS_CANDIDATES',
            'Possible matches: ' +
                ambiguity.topName! +
                ' or ' +
                ambiguity.secondName! +
                '.',
          ),
        );
      }
    }

    final exactCatalogHit = exactMatches.length == 1;
    final catalogKnown = item.catalogMatchName != null;

    if (!hasCatalog) {
      reasons.add(const VoiceGateReason(
        'NO_CATALOG',
        'Catalog validation is unavailable, so automatic billing approval is disabled.',
      ));
    } else if (!exactCatalogHit && !catalogKnown) {
      reasons.add(const VoiceGateReason(
        'NO_DETERMINISTIC_CATALOG_MATCH',
        'The product was not deterministically matched to the store catalog.',
      ));
    }

    final canAutoAccept = confidence >= autoAcceptThreshold &&
        hasCatalog &&
        (exactCatalogHit || catalogKnown) &&
        !ambiguity.isAmbiguous;

    if (canAutoAccept) {
      return const VoiceGateResult(
        decision: VoiceGateDecision.autoAccept,
      );
    }

    return VoiceGateResult(
      decision: VoiceGateDecision.requiresConfirmation,
      reasons: reasons.isEmpty
          ? const [
              VoiceGateReason(
                'REVIEW_REQUIRED',
                'Please verify the detected product, quantity, and price.',
              ),
            ]
          : reasons,
    );
  }

  /// Validate fields after the user edits a parsed item in the UI.
  static List<VoiceGateReason> validateManualFields({
    required String name,
    required double qty,
    required double price,
    required String unit,
  }) {
    final reasons = <VoiceGateReason>[];
    final normalizedName = _normalize(name);
    final normalizedUnit = _normalize(unit);

    if (normalizedName.length < 2) {
      reasons.add(const VoiceGateReason(
        'INVALID_PRODUCT_NAME',
        'Product name is too short.',
      ));
    } else if (_invalidNames.contains(normalizedName)) {
      reasons.add(const VoiceGateReason(
        'INVALID_PRODUCT_NAME',
        'Product name is not a valid sellable product.',
      ));
    }

    if (!qty.isFinite || qty <= 0 || qty > 500) {
      reasons.add(const VoiceGateReason(
        'INVALID_QUANTITY',
        'Quantity must be greater than 0 and no more than 500.',
      ));
    }

    if (!price.isFinite || price < 0 || price > 1000000) {
      reasons.add(const VoiceGateReason(
        'INVALID_PRICE',
        'Price must be between 0 and 1,000,000.',
      ));
    }

    if (!_supportedUnits.contains(normalizedUnit)) {
      reasons.add(
        VoiceGateReason(
          'INVALID_UNIT',
          'Unit "' + unit + '" is not a supported billing unit.',
        ),
      );
    }

    return reasons;
  }

  static List<Map<String, dynamic>> _exactCatalogMatches(
    String name,
    List<Map<String, dynamic>> catalog,
  ) {
    final key = _normalize(name);
    return catalog.where((p) {
      final candidate = _normalize(
        (p['name'] ?? p['product_name'] ?? '').toString(),
      );
      return candidate == key;
    }).toList();
  }

  static _Ambiguity _findCatalogAmbiguity(
    String name,
    List<Map<String, dynamic>> catalog,
  ) {
    final query = _normalize(name);
    if (query.length < 2) return const _Ambiguity.none();

    final ranked = <_CatalogScore>[];
    for (final product in catalog) {
      final candidate = _normalize(
        (product['name'] ?? product['product_name'] ?? '').toString(),
      );
      if (candidate.isEmpty) continue;
      ranked.add(
        _CatalogScore(
          name: (product['name'] ?? product['product_name'] ?? '').toString(),
          score: _similarity(query, candidate),
        ),
      );
    }

    ranked.sort((a, b) => b.score.compareTo(a.score));
    if (ranked.length < 2) return const _Ambiguity.none();

    final first = ranked[0];
    final second = ranked[1];

    final ambiguous = first.score >= 0.72 &&
        second.score >= 0.72 &&
        (first.score - second.score).abs() <= 0.08 &&
        _normalize(first.name) != query;

    return ambiguous
        ? _Ambiguity(
            topName: first.name,
            secondName: second.name,
            topScore: first.score,
            secondScore: second.score,
          )
        : const _Ambiguity.none();
  }

  /// Lowercase, remove zero-width joiners, collapse punctuation and whitespace,
  /// while preserving Unicode letters/numbers used by Indian scripts.
  static String _normalize(String input) {
    return input
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[\u200C\u200D]'), '')
        .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  static double _similarity(String a, String b) {
    if (a == b) return 1.0;
    if (a.isEmpty || b.isEmpty) return 0.0;

    if (a.length >= 4 && (a.contains(b) || b.contains(a))) {
      return 0.92;
    }

    final tokenScore = _tokenJaccard(a, b);
    final bigramScore = _bigramDice(a, b);
    return tokenScore > bigramScore ? tokenScore : bigramScore;
  }

  static double _tokenJaccard(String a, String b) {
    final as = a.split(' ').where((e) => e.isNotEmpty).toSet();
    final bs = b.split(' ').where((e) => e.isNotEmpty).toSet();
    if (as.isEmpty || bs.isEmpty) return 0.0;
    final intersection = as.intersection(bs).length;
    final union = as.union(bs).length;
    return union == 0 ? 0.0 : intersection / union;
  }

  static double _bigramDice(String a, String b) {
    final ar = a.runes.toList();
    final br = b.runes.toList();
    if (ar.length < 2 || br.length < 2) return 0.0;

    final aa = <String>{};
    final bb = <String>{};
    for (var i = 0; i < ar.length - 1; i++) {
      aa.add(String.fromCharCodes([ar[i], ar[i + 1]]));
    }
    for (var i = 0; i < br.length - 1; i++) {
      bb.add(String.fromCharCodes([br[i], br[i + 1]]));
    }
    final overlap = aa.intersection(bb).length;
    return (2 * overlap) / (aa.length + bb.length);
  }
}

class _CatalogScore {
  final String name;
  final double score;

  const _CatalogScore({
    required this.name,
    required this.score,
  });
}

class _Ambiguity {
  final String? topName;
  final String? secondName;
  final double topScore;
  final double secondScore;

  const _Ambiguity({
    this.topName,
    this.secondName,
    this.topScore = 0,
    this.secondScore = 0,
  });

  const _Ambiguity.none()
      : topName = null,
        secondName = null,
        topScore = 0,
        secondScore = 0;

  bool get isAmbiguous => topName != null && secondName != null;
}
