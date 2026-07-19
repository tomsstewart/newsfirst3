-- Eight sources (six www/trailing-slash twins seeded by the gn promotion, plus
-- NBC News and Live Science moved feeds) redirect onto a URL another source row
-- already owns. Ingest's persist-permanent-move PATCH then violates
-- sources_feed_url_key on every 5-min poll — the duplicate-key log spam.
-- Merge each loser into the row that owns the canonical URL; ingest v40 disables
-- any future such duplicate with health='duplicate' instead of retrying forever.

alter table public.sources drop constraint sources_health_check;
alter table public.sources add constraint sources_health_check
  check (health = any (array['ok'::text, 'degraded'::text, 'broken'::text, 'duplicate'::text]));

-- Repoint articles to the keeper…
with pairs(loser_url, keeper_url) as (
  values
    ('https://today.uic.edu/feed',                 'https://today.uic.edu/feed/'),
    ('https://swansea.ac.uk/press-office/rss.xml', 'https://www.swansea.ac.uk/press-office/rss.xml'),
    ('https://cidrap.umn.edu/rss.xml',             'https://www.cidrap.umn.edu/rss.xml'),
    ('https://football365.com/rss',                'https://www.football365.com/rss'),
    ('https://brighton-hove.gov.uk/rss.xml',       'https://www.brighton-hove.gov.uk/rss.xml'),
    ('https://health-ni.gov.uk/rss.xml',           'https://www.health-ni.gov.uk/rss.xml'),
    ('https://nbcnews.com/feed',                   'https://feeds.nbcnews.com/nbcnews/public/news'),
    ('https://www.livescience.com/feeds/all',      'https://www.livescience.com/feeds.xml')
),
ids as (
  select l.id as loser_id, k.id as keeper_id
  from pairs p
  join public.sources l on l.feed_url = p.loser_url
  join public.sources k on k.feed_url = p.keeper_url
)
update public.articles a set source_id = ids.keeper_id
from ids where a.source_id = ids.loser_id;

-- …then delete the loser rows (separate statement: RI must see the repoint).
with pairs(loser_url, keeper_url) as (
  values
    ('https://today.uic.edu/feed',                 'https://today.uic.edu/feed/'),
    ('https://swansea.ac.uk/press-office/rss.xml', 'https://www.swansea.ac.uk/press-office/rss.xml'),
    ('https://cidrap.umn.edu/rss.xml',             'https://www.cidrap.umn.edu/rss.xml'),
    ('https://football365.com/rss',                'https://www.football365.com/rss'),
    ('https://brighton-hove.gov.uk/rss.xml',       'https://www.brighton-hove.gov.uk/rss.xml'),
    ('https://health-ni.gov.uk/rss.xml',           'https://www.health-ni.gov.uk/rss.xml'),
    ('https://nbcnews.com/feed',                   'https://feeds.nbcnews.com/nbcnews/public/news'),
    ('https://www.livescience.com/feeds/all',      'https://www.livescience.com/feeds.xml')
)
delete from public.sources s
using pairs p, public.sources k
where s.feed_url = p.loser_url and k.feed_url = p.keeper_url;
