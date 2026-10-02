-- Keep historical text untouched. The application supplies its current alias
-- dictionary from config/cities.json; no extension or separate catalog copy.
CREATE FUNCTION normalize_location(value text) RETURNS text
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE AS $$
 SELECT regexp_replace(lower(normalize(regexp_replace(normalize(value,NFD), U&'[\0300-\036f]', '', 'g'), NFC)), '[^a-z0-9가-힣]', '', 'g')
$$;

-- Unknown names are opaque, case-sensitive identities. Preserve their scripts
-- and punctuation, compose Unicode, and trim exactly JavaScript's whitespace.
-- This does not require extensions, ICU, or a particular database locale.
CREATE FUNCTION legacy_location_text(value text) RETURNS text
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE AS $$
 SELECT btrim(normalize(value,NFC), U&'\0009\000a\000b\000c\000d\0020\00a0\1680\2000\2001\2002\2003\2004\2005\2006\2007\2008\2009\200a\2028\2029\202f\205f\3000\feff')
$$;

CREATE FUNCTION location_identity(country text, city text, aliases jsonb) RETURNS text
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE AS $$
 SELECT coalesce(aliases->'cities'->>(country_code || ':' || normalize_location(city)),
   'legacy:[' || to_json(coalesce(country_code,legacy_location_text(country)))::text || ',' ||
                 to_json(legacy_location_text(city))::text || ']')
 FROM (SELECT aliases->'countries'->>normalize_location(country) AS country_code) normalized
$$;
