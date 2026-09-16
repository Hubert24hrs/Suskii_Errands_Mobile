import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:suskii_domain/suskii_domain.dart';

import '../tokens/spacing.dart';

/// Labeled text field wired to the design-system input theme.
class STextField extends StatelessWidget {
  const STextField({
    required this.label,
    super.key,
    this.controller,
    this.hint,
    this.errorText,
    this.keyboardType,
    this.maxLines = 1,
    this.textInputAction,
    this.onChanged,
    this.semanticLabel,
  });

  final String label;
  final TextEditingController? controller;
  final String? hint;
  final String? errorText;
  final TextInputType? keyboardType;
  final int maxLines;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onChanged;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(label, style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: SSpacing.xs),
        TextField(
          controller: controller,
          keyboardType: keyboardType,
          maxLines: maxLines,
          textInputAction: textInputAction,
          onChanged: onChanged,
          decoration: InputDecoration(hintText: hint, errorText: errorText),
        ),
      ],
    );
  }
}

class SDialCode {
  const SDialCode({required this.countryCode, required this.dialCode});

  final String countryCode;
  final String dialCode;
}

/// Phone input with country dial-code picker.
class SPhoneField extends StatelessWidget {
  const SPhoneField({
    required this.label,
    required this.codes,
    required this.selectedCode,
    required this.onCodeChanged,
    super.key,
    this.controller,
    this.errorText,
    this.onChanged,
  });

  final String label;
  final List<SDialCode> codes;
  final SDialCode selectedCode;
  final ValueChanged<SDialCode> onCodeChanged;
  final TextEditingController? controller;
  final String? errorText;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(label, style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: SSpacing.xs),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            SizedBox(
              height: SSpacing.minTouchTarget,
              child: DropdownMenu<SDialCode>(
                initialSelection: selectedCode,
                onSelected: (SDialCode? code) {
                  if (code != null) onCodeChanged(code);
                },
                dropdownMenuEntries: codes
                    .map(
                      (SDialCode c) => DropdownMenuEntry<SDialCode>(
                        value: c,
                        label: '${c.countryCode} ${c.dialCode}',
                      ),
                    )
                    .toList(),
                width: 140,
              ),
            ),
            const SizedBox(width: SSpacing.sm),
            Expanded(
              child: TextField(
                controller: controller,
                keyboardType: TextInputType.phone,
                inputFormatters: <TextInputFormatter>[
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9 ]')),
                ],
                onChanged: onChanged,
                decoration: InputDecoration(errorText: errorText),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// Currency amount input. Emits INTEGER MINOR UNITS only — the exponent comes
/// from the currency's ISO 4217 table (e.g. XOF has no decimal part).
class SMoneyField extends StatelessWidget {
  const SMoneyField({
    required this.label,
    required this.currencyCode,
    super.key,
    this.controller,
    this.errorText,
    this.onChangedMinorUnits,
  });

  final String label;
  final String currencyCode;
  final TextEditingController? controller;
  final String? errorText;
  final ValueChanged<int?>? onChangedMinorUnits;

  void _handle(String raw) {
    final callback = onChangedMinorUnits;
    if (callback == null) return;
    final cleaned = raw.replaceAll(RegExp('[^0-9.]'), '');
    if (cleaned.isEmpty) {
      callback(null);
      return;
    }
    final exponent = Money.exponentOf(currencyCode);
    final parts = cleaned.split('.');
    final whole = int.tryParse(parts.first.isEmpty ? '0' : parts.first) ?? 0;
    var minor = whole;
    for (var i = 0; i < exponent; i++) {
      minor *= 10;
    }
    if (exponent > 0 && parts.length > 1) {
      final fracRaw = parts[1].length > exponent
          ? parts[1].substring(0, exponent)
          : parts[1].padRight(exponent, '0');
      minor += int.tryParse(fracRaw) ?? 0;
    }
    callback(minor);
  }

  @override
  Widget build(BuildContext context) {
    final exponent = Money.exponentOf(currencyCode);
    final prefix = Money(0, currencyCode).symbol;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(label, style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: SSpacing.xs),
        TextField(
          controller: controller,
          keyboardType: TextInputType.numberWithOptions(decimal: exponent > 0),
          inputFormatters: <TextInputFormatter>[
            FilteringTextInputFormatter.allow(
              RegExp(exponent > 0 ? r'[0-9.]' : '[0-9]'),
            ),
          ],
          onChanged: _handle,
          decoration: InputDecoration(prefixText: prefix, errorText: errorText),
        ),
      ],
    );
  }
}
