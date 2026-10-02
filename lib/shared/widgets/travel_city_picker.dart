import 'package:flutter/material.dart';

import '../../core/geo/city_catalog.g.dart';

/// Purely local search: usable before GPS, tiles or the API finish loading.
Future<TravelCity?> showTravelCityPicker(BuildContext context) =>
    showDialog<TravelCity>(
      context: context,
      builder: (_) => const _TravelCityPicker(),
    );

class _TravelCityPicker extends StatefulWidget {
  const _TravelCityPicker();

  @override
  State<_TravelCityPicker> createState() => _TravelCityPickerState();
}

class _TravelCityPickerState extends State<_TravelCityPicker> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final query = CityCatalog.normalize(_query);
    final cities = CityCatalog.knownPlaces
        .where(
          (city) => [
            city.city,
            city.cityKo,
            city.country,
            city.countryKo,
            city.nativeName,
            ...city.aliases,
          ].any((value) => CityCatalog.normalize(value).contains(query)),
        )
        .toList();
    return AlertDialog(
      title: const Text('도시 선택'),
      content: SizedBox(
        width: 440,
        height:
            (MediaQuery.sizeOf(context).height -
                MediaQuery.viewInsetsOf(context).bottom) *
            .5,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const ValueKey('travel-city-search'),
              decoration: const InputDecoration(
                labelText: '도시 · 국가',
                prefixIcon: Icon(Icons.search),
              ),
              onChanged: (value) => setState(() => _query = value),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: cities.isEmpty
                  ? const Center(child: Text('목록에 없는 도시예요. 다른 도시를 검색해주세요.'))
                  : ListView.builder(
                      itemCount: cities.length,
                      itemBuilder: (context, index) {
                        final city = cities[index];
                        return ListTile(
                          key: ValueKey('select-city-${city.id}'),
                          title: Text('${city.cityKo} · ${city.city}'),
                          subtitle: Text(city.countryKo),
                          onTap: () => Navigator.pop(context, city),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('닫기'),
        ),
      ],
    );
  }
}
