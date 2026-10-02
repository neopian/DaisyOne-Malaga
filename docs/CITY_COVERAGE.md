# Europe and US city scope

The owner chose **major European and US cities** and **virtual points plus reputation** for the initial model on 2026-10-02. The service name remains undecided. The repository and private preview hostname are technical identifiers, not the proposed brand.

## Editable development catalog

`config/cities.json` is the single catalog source. The committed Dart catalog is generated from it; the Node API and browser preview use the same city identities and aliases. Run `node scripts/generate-city-catalog.mjs` after an approved catalog edit, and `node scripts/generate-city-catalog.mjs --check` during verification. Ship the API, client and preview changes together.

The following **20 entries are an implementation proposal**, not an approved city-by-city rollout or a claim that guides are available:

- Europe: London, Paris, Rome, Amsterdam, Berlin, Lisbon, Barcelona, Madrid, Prague, Vienna, Zurich, Málaga
- US: New York, Los Angeles, San Francisco, Chicago, Boston, Washington DC, Seattle, Las Vegas

Málaga is retained as a legacy development fixture. It has no special branding or launch priority. Final city selection and staged opening depend on real guide supply, language coverage and moderation capacity. A broad geographic direction does not justify claiming all-day coverage across both continents.

## Location behavior

- Questions and guide applications use catalog choices. Country and city aliases are normalized together, preventing a city name from being silently accepted under another country.
- Travelers can choose a destination before travel, without GPS, map tiles, reverse geocoding or an external lookup. The map can show and navigate both continents.
- GPS proposes a nearby catalog city within a configurable 60 km association distance. This is a coarse selection aid, **not** a territorial boundary or a service radius. The interface asks the traveler to check the suggested city. Elsewhere, manual selection remains available.
- Existing historical questions remain readable and their assigned answer/reward workflow remains valid. Removing a city from new selections must not delete earlier records or invalidate an already acknowledged idempotent retry. Known catalog aliases are matched together; unknown historical names require an exact NFC-normalized, trimmed, case-sensitive pair. This conservative fallback can narrow legacy text matches and deliberately does not infer that two unfamiliar city names refer to the same place.
- No location is transmitted to a new geocoding service by this change. Map tiles remain the existing OpenStreetMap integration; its production usage policy and capacity still require deployment review.

## Initial reward and reputation model

Points cannot be purchased, redeemed or cashed out and have no monetary value. Existing transactional holds, awards and returns stay in place. Reputation is the factual count of accepted answers and the guide's recorded activity regions. It is not a star rating, identity certification, qualification or accuracy guarantee.

The exact free-point allocation/replenishment rules, unfulfilled assigned-question policy, disputes and moderation operations remain launch decisions. No real payment provider, Apple purchase integration or payout account has been connected.
