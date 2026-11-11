# Recipe: Instagram Reel insights in the iOS app

The Instagram app shows per-reel insights that the web does not: the retention curve, skip rate, rates
compared with the account's typical reel, and where the views came from. This recipe reads them through
iPhone Mirroring. **It is read-only:** do not like, comment, share, boost or edit anything. Do not double-tap
the video, because that likes it.

The account must be a professional (creator or business) account, logged in on the phone. Coordinates below
were observed on a 354x781 pt window, so treat them as hints and always read the real ones from your
screenshot.

## Path

1. **Profile grid.** Use the profile tab, the rightmost icon in the bottom tab bar. The grid of posts and reels
   is below the header (bio, buttons, highlights). Scroll until the item you want is visible.
2. **Open the reel.** Tap its thumbnail. One of two screens opens:
   - the **Posts list** (feed-style, the video with its caption, and a **"View insights"** link at the
     bottom-left under the video, next to a blue "Boost" button: **never tap Boost**, it is paid promotion);
   - the **full-screen Reels viewer**, which has no insights link in the same place.

   Which one opens is not consistent. If you get the viewer, go back (top-left chevron, about (37, 103)) and
   tap the thumbnail again. The blue Boost button is a cheap pixel check for "Posts list". See
   [scripting.md](scripting.md).
3. **Insights.** Tap "View insights" (about (75, 733) in the Posts list). The **Reel insights** screen has the
   tabs **Overview / Engagement / Audience** (about y=391; Overview about x=65, Engagement about x=177).
4. **Overview** (scroll down 2–3 times with `scroll -60 --times 8`, then `join` the shots):
   - views, viewers (accounts reached), average watch time, follows;
   - **skip rate** (share of viewers who scrolled past in the first seconds);
   - share, like, save, repost and comment rates, each **compared with the account's typical reel**;
   - the **retention curve** (share of viewers still watching over the length of the video);
   - **sources of views** (Reels tab, Feed, Profile, Explore, Stories...).
5. **Engagement:** profile visits, follows, and **bio link clicks**. **That row is hidden when it is 0**, so
   treat a missing row as 0, not as "not loaded".
6. **Audience:** demographics (countries, cities, age, gender). It only appears once a reel has enough viewers.
7. **Back** with the top-left chevron. Before the next item, check that you are on the grid again.

## Account level

From the profile, open the **Professional dashboard**, then the **Performance** tab. It has account-level
profile visits and bio link taps for the selected period. This data **lags about one day**: today's numbers
are incomplete.

## Tips

- Record every number in a table as you go (reel, date, views, avg watch time, skip rate, follows, profile
  visits, link clicks, top source). Re-reading screenshots later costs more tokens than writing a row now.
- Numbers may be abbreviated ("1.2K"). Note the rounding.
- Instagram changes labels and layout often. Recognise screens by their titles and tabs, not by fixed
  coordinates.
- Labels follow the phone's language. On a non-English phone, match the screens by meaning (insights link,
  three tabs), not by the English words above.
