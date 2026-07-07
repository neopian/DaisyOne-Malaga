import 'package:flutter/material.dart';

class LocationInputSection extends StatelessWidget {
  const LocationInputSection({
    super.key,
    required this.countryController,
    required this.cityController,
    this.regionController,
    required this.isEditing,
    required this.isLoading,
    required this.onEdit,
    required this.onDone,
    required this.onUseCurrentLocation,
    this.errorText,
    this.lockCountry = false,
  });

  final TextEditingController countryController;
  final TextEditingController cityController;
  final TextEditingController? regionController;
  final bool isEditing;
  final bool isLoading;
  final VoidCallback onEdit;
  final VoidCallback onDone;
  final VoidCallback onUseCurrentLocation;
  final String? errorText;
  final bool lockCountry;

  String get _locationLabel {
    final country = countryController.text.trim();
    final city = cityController.text.trim();
    final region = regionController?.text.trim() ?? '';
    if (country.isEmpty && city.isEmpty) return '';
    return [
      [country, city].where((value) => value.isNotEmpty).join(' '),
      if (region.isNotEmpty) region,
    ].join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    if (isEditing) return _EditingLocationFields(section: this);
    return _LocationSummary(section: this);
  }
}

class _LocationSummary extends StatelessWidget {
  const _LocationSummary({required this.section});

  final LocationInputSection section;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final label = section._locationLabel;
    final statusText = label.isEmpty
        ? section.isLoading
              ? '위치 확인 중'
              : '위치가 설정되지 않았습니다'
        : label;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Icon(
              label.isEmpty ? Icons.location_searching : Icons.place_outlined,
              color: scheme.primary,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('현재 위치', style: Theme.of(context).textTheme.labelLarge),
                  const SizedBox(height: 3),
                  Text(
                    statusText,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyLarge,
                  ),
                  if (section.errorText != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      section.errorText!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (section.isLoading)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8),
                child: SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            else
              IconButton(
                tooltip: '현재 위치 새로고침',
                onPressed: section.onUseCurrentLocation,
                icon: const Icon(Icons.my_location_outlined),
              ),
            TextButton.icon(
              onPressed: section.onEdit,
              icon: const Icon(Icons.edit_location_alt_outlined),
              label: const Text('변경'),
            ),
          ],
        ),
      ),
    );
  }
}

class _EditingLocationFields extends StatelessWidget {
  const _EditingLocationFields({required this.section});

  final LocationInputSection section;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            if (section.lockCountry)
              Expanded(
                child: InputDecorator(
                  decoration: const InputDecoration(labelText: '국가'),
                  child: Text(
                    section.countryController.text.trim().isEmpty
                        ? 'Spain'
                        : section.countryController.text.trim(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              )
            else
              Expanded(
                child: TextFormField(
                  controller: section.countryController,
                  decoration: const InputDecoration(labelText: '국가'),
                  validator: (value) =>
                      value == null || value.trim().isEmpty ? '필수' : null,
                ),
              ),
            const SizedBox(width: 10),
            Expanded(
              child: TextFormField(
                controller: section.cityController,
                decoration: const InputDecoration(labelText: '도시'),
                validator: (value) =>
                    value == null || value.trim().isEmpty ? '필수' : null,
              ),
            ),
          ],
        ),
        if (section.regionController != null) ...[
          const SizedBox(height: 12),
          TextFormField(
            controller: section.regionController,
            decoration: const InputDecoration(
              labelText: '지역',
              prefixIcon: Icon(Icons.place_outlined),
            ),
          ),
        ],
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: section.isLoading
                    ? null
                    : section.onUseCurrentLocation,
                icon: section.isLoading
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.my_location_outlined),
                label: const Text('내 위치'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: FilledButton.icon(
                onPressed: section.onDone,
                icon: const Icon(Icons.check),
                label: const Text('완료'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
