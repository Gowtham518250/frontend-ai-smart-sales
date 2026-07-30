import 'package:decimal/decimal.dart';

/// GST Calculator Service
/// Provides precise GST calculations using decimal arithmetic
/// to avoid floating-point errors in financial calculations
class GstCalculator {
  /// Calculate GST components for a single item
  static GstComponents calculateItemGST({
    required double price,
    required int quantity,
    required double gstRate,
  }) {
    final priceDecimal = Decimal.parse(price.toString());
    final quantityDecimal = Decimal.fromInt(quantity);
    final gstRateDecimal = Decimal.parse(gstRate.toString()) / Decimal.fromInt(100);
    
    final lineTotal = priceDecimal * quantityDecimal;
    final lineGST = lineTotal * gstRateDecimal;
    final halfGST = (lineGST / Decimal.fromInt(2)).toDecimal(scale: 2);
    
    return GstComponents(
      subtotal: lineTotal.toDouble(),
      cgst: halfGST.toDouble(),
      sgst: halfGST.toDouble(),
      totalGST: lineGST.toDouble(),
      grandTotal: (lineTotal + lineGST).toDouble(),
    );
  }
  
  /// Calculate GST for multiple items
  static GstComponents calculateBatchGST({
    required List<GstItem> items,
  }) {
    Decimal totalSubtotal = Decimal.zero;
    Decimal totalCGST = Decimal.zero;
    Decimal totalSGST = Decimal.zero;
    Decimal totalGST = Decimal.zero;
    
    for (final item in items) {
      final quantity = Decimal.fromInt(item.quantity);
      final price = Decimal.parse(item.price.toString());
      final lineTotal = quantity * price;
      
      totalSubtotal += lineTotal;
      
      if (item.gstRate != null && item.gstRate! > 0) {
        final gstRate = Decimal.parse(item.gstRate.toString()) / Decimal.fromInt(100);
        final lineGST = lineTotal * gstRate;
        final halfGST = (lineGST / Decimal.fromInt(2)).toDecimal(scale: 2);
        
        totalCGST += halfGST;
        totalSGST += halfGST;
        totalGST += lineGST;
      }
    }
    
    final grandTotal = totalSubtotal + totalGST;
    
    return GstComponents(
      subtotal: totalSubtotal.toDouble(),
      cgst: totalCGST.toDouble(),
      sgst: totalSGST.toDouble(),
      totalGST: totalGST.toDouble(),
      grandTotal: grandTotal.toDouble(),
    );
  }
  
  /// Calculate discount-aware GST (discount applied before tax)
  static GstComponents calculateWithDiscount({
    required double price,
    required int quantity,
    required double discountPercent,
    required double gstRate,
  }) {
    final priceDecimal = Decimal.parse(price.toString());
    final quantityDecimal = Decimal.fromInt(quantity);
    final discountDecimal = Decimal.parse(discountPercent.toString()) / Decimal.fromInt(100);
    final gstRateDecimal = Decimal.parse(gstRate.toString()) / Decimal.fromInt(100);
    
    final lineTotal = priceDecimal * quantityDecimal;
    final discountAmount = lineTotal * discountDecimal;
    final discountedPrice = lineTotal - discountAmount;
    
    final lineGST = discountedPrice * gstRateDecimal;
    final halfGST = (lineGST / Decimal.fromInt(2)).toDecimal(scale: 2);
    
    return GstComponents(
      subtotal: lineTotal.toDouble(),
      discountAmount: discountAmount.toDouble(),
      discountedPrice: discountedPrice.toDouble(),
      cgst: halfGST.toDouble(),
      sgst: halfGST.toDouble(),
      totalGST: lineGST.toDouble(),
      grandTotal: (discountedPrice + lineGST).toDouble(),
    );
  }
  
  /// Round to 2 decimal places (paise)
  static double roundToPaise(double value) {
    return (Decimal.parse(value.toString()).toDecimal(scale: 2)).toDouble();
  }
}

/// GST calculation result components
class GstComponents {
  final double subtotal;
  final double cgst;
  final double sgst;
  final double totalGST;
  final double grandTotal;
  final double? discountAmount;
  final double? discountedPrice;
  
  GstComponents({
    required this.subtotal,
    required this.cgst,
    required this.sgst,
    required this.totalGST,
    required this.grandTotal,
    this.discountAmount,
    this.discountedPrice,
  });
  
  @override
  String toString() {
    return 'GstComponents(subtotal: $subtotal, cgst: $cgst, sgst: $sgst, totalGST: $totalGST, grandTotal: $grandTotal)';
  }
}

/// Item for GST calculation
class GstItem {
  final double price;
  final int quantity;
  final double? gstRate;
  
  GstItem({
    required this.price,
    required this.quantity,
    this.gstRate,
  });
}