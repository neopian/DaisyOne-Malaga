import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../core/geo/city_catalog.g.dart';
import '../../core/services/location_service.dart';
import 'travel_question_support.dart';
import '../../shared/widgets/travel_city_picker.dart';

/// A city list works even when location permission or map tiles are unavailable.
/// Catalog city centers are selections, not territorial or availability claims.
class TravelLocationSection extends StatefulWidget {
  const TravelLocationSection({
    super.key,
    required this.location,
    required this.isManual,
    required this.isLoading,
    required this.enabled,
    required this.onCitySelected,
    required this.onUseCurrentLocation,
    this.errorText,
    this.tileProvider,
  });

  final DeviceLocation? location;
  final bool isManual;
  final bool isLoading;
  final bool enabled;
  final ValueChanged<TravelCity> onCitySelected;
  final VoidCallback onUseCurrentLocation;
  final String? errorText;
  final TileProvider? tileProvider;

  @override
  State<TravelLocationSection> createState() => _TravelLocationSectionState();
}

class _TravelLocationSectionState extends State<TravelLocationSection> {
  bool _showMap = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final location = widget.location;
    final knownCity = location == null
        ? null
        : CityCatalog.findCity(location.country, location.city);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('질문할 도시', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              '유럽·미국에서 여행 중이거나 방문할 도시를 선택해주세요.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 20),
            OutlinedButton.icon(
              key: const ValueKey('travel-city-select'),
              onPressed: widget.enabled
                  ? () async {
                      final city = await showTravelCityPicker(context);
                      if (!mounted || !widget.enabled || city == null) return;
                      widget.onCitySelected(city);
                    }
                  : null,
              icon: const Icon(Icons.location_city_outlined),
              label: Text(
                knownCity == null
                    ? '여행 도시 직접 선택'
                    : '${knownCity.cityKo} · ${knownCity.countryKo} 변경',
              ),
            ),
            if (location != null) ...[
              const SizedBox(height: 12),
              Text(
                '${CityCatalog.countryLabel(location.country)} · ${travelCityLabel(location.city, country: location.country)}',
                key: const ValueKey('question-location-summary'),
                style: theme.textTheme.labelLarge?.copyWith(
                  color: scheme.primary,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                widget.isManual
                    ? '선택한 도시 중심에 표시됩니다. 정확한 장소는 질문 내용에 적어주세요.'
                    : '현재 위치와 가까운 도시를 선택했어요. 질문할 도시가 맞는지 확인해주세요.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
            if (widget.errorText != null) ...[
              const SizedBox(height: 12),
              Semantics(
                liveRegion: true,
                child: Text(
                  widget.errorText!,
                  key: const ValueKey('question-location-error'),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
            const SizedBox(height: 12),
            TextButton.icon(
              onPressed: widget.enabled && !widget.isLoading
                  ? widget.onUseCurrentLocation
                  : null,
              icon: widget.isLoading
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.my_location_outlined),
              label: Text(
                widget.isLoading ? '현재 위치 확인 중' : '내 위치 사용',
                textAlign: TextAlign.center,
              ),
            ),
            TextButton.icon(
              onPressed: widget.enabled
                  ? () => setState(() => _showMap = !_showMap)
                  : null,
              icon: Icon(_showMap ? Icons.expand_less : Icons.map_outlined),
              label: Text(
                _showMap ? '지도 접기' : '지도에서 도시 선택',
                textAlign: TextAlign.center,
              ),
            ),
            if (_showMap) ...[
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: SizedBox(
                  height: 240,
                  child: IgnorePointer(
                    ignoring: !widget.enabled,
                    child: FlutterMap(
                      key: ValueKey(
                        'travel-map-${knownCity?.city ?? 'overview'}',
                      ),
                      options: MapOptions(
                        initialCenter: LatLng(
                          knownCity?.latitude ?? 44.0,
                          knownCity?.longitude ?? -35.0,
                        ),
                        initialZoom: knownCity == null ? 2 : 9,
                        minZoom: 2,
                        maxZoom: 13,
                        interactionOptions: const InteractionOptions(
                          flags:
                              InteractiveFlag.drag |
                              InteractiveFlag.pinchMove |
                              InteractiveFlag.pinchZoom |
                              InteractiveFlag.doubleTapZoom,
                        ),
                      ),
                      children: [
                        TileLayer(
                          urlTemplate:
                              'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                          userAgentPackageName: 'local_qa_concierge',
                          tileProvider: widget.tileProvider,
                        ),
                        MarkerLayer(
                          markers: [
                            for (final place in CityCatalog.knownPlaces)
                              Marker(
                                point: LatLng(place.latitude, place.longitude),
                                width: 48,
                                height: 48,
                                child: IconButton(
                                  key: ValueKey(
                                    'travel-map-city-${place.city}',
                                  ),
                                  tooltip: '${travelCityLabel(place.city)} 선택',
                                  onPressed: widget.enabled
                                      ? () => widget.onCitySelected(place)
                                      : null,
                                  icon: Icon(
                                    Icons.location_on,
                                    color: place.city == knownCity?.city
                                        ? scheme.primary
                                        : scheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                          ],
                        ),
                        const SimpleAttributionWidget(
                          source: Text('OpenStreetMap contributors'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                '확대해서 도시 핀을 누르세요. 지도가 로드되지 않아도 위 도시 목록으로 선택할 수 있어요.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
