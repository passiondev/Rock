"""The facilitator script describes a deck it cannot see, three times over.

`Facilitator-Script-Rock-CICD-Training.md` encodes the same run of slides in three
places -- a timing plan, a slide map, and the segment notes -- and none of them is
generated from `rock-cicd-training-deck.html`. Every one of them goes stale silently:
the deck still renders, the script still reads fluently, and the mismatch only
surfaces when somebody is standing in front of the room.

It has gone stale twice. A slide was cut from "Git in five minutes" and every
reference after it pointed one slide too far. Then slide 9 was retitled when the
material was made branch-name-free and the slide map kept the old heading. Both were
caught by a human reading two files side by side, which is not a control.

What is checked here is only what is genuinely one fact written twice. Segment
*names* are deliberately not compared: the timing plan says "Open — why this exists"
where the segment notes say "Open", and the slide map's Section column uses a third
vocabulary again ("Q&A + asks" spans two sections named "Questions you're about to
ask" and "Where we go from here"). Those differ on purpose. Pinning them equal would
fail on correct prose and teach the next person to delete the test.
"""

import html
import re
import unittest

import pipeline_harness as harness


REPO_ROOT = harness.REPO_ROOT
TRAINING_DIR = REPO_ROOT / "Documentation" / "Training"
DECK = TRAINING_DIR / "rock-cicd-training-deck.html"
SCRIPT = TRAINING_DIR / "Facilitator-Script-Rock-CICD-Training.md"

SLIDE_SECTION = re.compile(r'<section class="slide[^"]*" id="(s\d+)">(.*?)</section>', re.S)
RAIL_NODE = re.compile(r'<a class="rail-node" href="#(s\d+)"')
SLIDE_HEADING = re.compile(r"<h[12][^>]*>(.*?)</h[12]>", re.S)

# | 0:04 | 8 | Git in five minutes | 3-5 | Land this one point. |
TIMING_ROW = re.compile(r"^\| (\d+:\d\d) \| (\d+) \| (.+?) \| ([\d–-]+) \| .+ \|$", re.M)
# | 9 | Version branches | How an upgrade moves the trunk under you. |
SLIDE_MAP_ROW = re.compile(r"^\| (\d+) \| (.+?) \| (.+?) \|$", re.M)
# ### 0:18 - Version branches (slides 8-9, 4 min)
SEGMENT_HEADING = re.compile(
    r"^### (\d+:\d\d) — (.+?) \(slides? ([\d–-]+), (\d+) min\)$", re.M
)
PROSE_SLIDE_REF = re.compile(r"\b[Ss]lides? (\d+)(?:–(\d+))?")
STATED_SLOT = re.compile(r"\*\*Slot:\*\* (\d+) minutes")


def deck_slides():
    """Every slide as (id, heading), in deck order. The title slide carries an <h1>
    and the rest carry <h2>; both count as one slide, which is how the script numbers
    them.

    Slide ids are deliberately not assumed to equal the slide number. `s5` does not
    exist -- it was the slide cut from "Git in five minutes" -- and renumbering the
    rest would only move the rail's anchors for no gain. Order is what counts."""
    slides = []
    for slide_id, body in SLIDE_SECTION.findall(DECK.read_text()):
        found = SLIDE_HEADING.search(body)
        slides.append((slide_id, html.unescape(found.group(1)).strip() if found else None))
    return slides


def deck_headings():
    return [heading for _slide_id, heading in deck_slides()]


def section_start_slides(script):
    """The 1-based number of each slide that opens a new section, read off the slide
    map's Section column."""
    starts, previous = [], None
    for number, section, _heading in SLIDE_MAP_ROW.findall(script):
        if section != previous:
            starts.append(int(number))
        previous = section
    return starts


def parse_range(text):
    """`8-9`, `8–9` and `17` all become an inclusive list of slide numbers."""
    bounds = [int(part) for part in re.split(r"[–-]", text)]
    if len(bounds) == 1:
        return bounds
    return list(range(bounds[0], bounds[1] + 1))


def clock_to_minutes(clock):
    hours, minutes = clock.split(":")
    return int(hours) * 60 + int(minutes)


class SlideMapMatchesDeckTests(unittest.TestCase):
    def setUp(self):
        self.script = SCRIPT.read_text()
        self.headings = deck_headings()
        self.rows = SLIDE_MAP_ROW.findall(self.script)

    def test_the_deck_parses_into_slides_with_headings(self):
        """Guards every other test here: a markup change that stopped the section
        regex matching would leave them all comparing two empty lists."""
        self.assertGreater(len(self.headings), 10, "found almost no slides -- the deck parser has broken")
        self.assertNotIn(None, self.headings, "a slide has no <h1> or <h2> heading")

    def test_the_slide_map_has_a_row_per_slide(self):
        self.assertEqual(
            len(self.headings),
            len(self.rows),
            f"the deck has {len(self.headings)} slides and the slide map has {len(self.rows)} rows; "
            "every slide number in the timing plan and the segment notes is now off",
        )

    def test_every_slide_map_heading_matches_the_deck(self):
        mismatched = []
        for (number, _section, heading), actual in zip(self.rows, self.headings):
            if heading.strip() != actual:
                mismatched.append(f"  slide {number}: script says {heading.strip()!r}, deck says {actual!r}")

        self.assertEqual(
            [],
            mismatched,
            "the slide map has drifted from the deck:\n" + "\n".join(mismatched),
        )

    def test_the_slide_map_numbers_its_rows_consecutively_from_one(self):
        self.assertEqual(
            [str(n) for n in range(1, len(self.rows) + 1)],
            [number for number, _section, _heading in self.rows],
        )


class TimingPlanAgreesWithSegmentNotesTests(unittest.TestCase):
    def setUp(self):
        self.script = SCRIPT.read_text()
        self.timing = TIMING_ROW.findall(self.script)
        self.segments = SEGMENT_HEADING.findall(self.script)

    def test_both_encodings_were_actually_found(self):
        self.assertGreater(len(self.timing), 5, "the timing plan did not parse")
        self.assertEqual(
            len(self.timing),
            len(self.segments),
            f"the timing plan lists {len(self.timing)} segments and the segment notes "
            f"have {len(self.segments)} headings",
        )

    def test_each_segment_note_matches_its_timing_row(self):
        """Matched on the clock rather than the name, because the names differ on
        purpose -- see the module docstring."""
        by_clock = {clock: (minutes, slides) for clock, minutes, _name, slides in self.timing}

        for clock, name, slides, minutes in self.segments:
            self.assertIn(clock, by_clock, f"segment note {clock} — {name} is in no timing row")
            planned_minutes, planned_slides = by_clock[clock]
            self.assertEqual(
                int(planned_minutes),
                int(minutes),
                f"segment {clock} — {name}: timing plan says {planned_minutes} min, its note says {minutes}",
            )
            self.assertEqual(
                parse_range(planned_slides),
                parse_range(slides),
                f"segment {clock} — {name}: timing plan covers slides {planned_slides}, its note says {slides}",
            )

    def test_the_clock_is_contiguous_and_fills_the_stated_slot(self):
        """Each segment starts where the last one ended, and the last one ends on the
        slot boundary. A plan that quietly runs over is how a demo gets cut."""
        running = 0
        for clock, minutes, name, _slides in self.timing:
            self.assertEqual(
                running,
                clock_to_minutes(clock),
                f"segment {name} starts at {clock} but the segments before it end at "
                f"{running // 60}:{running % 60:02d}",
            )
            running += int(minutes)

        slot = int(STATED_SLOT.search(self.script).group(1))
        self.assertEqual(
            slot,
            running,
            f"the timing plan runs {running} minutes against a stated {slot}-minute slot",
        )

    def test_the_segments_cover_every_slide_exactly_once(self):
        covered = [slide for _clock, _min, _name, slides in self.timing for slide in parse_range(slides)]

        self.assertEqual(
            list(range(1, len(deck_headings()) + 1)),
            covered,
            "the timing plan's slide ranges are not a contiguous cover of the deck -- "
            "a slide is either presented twice or never reached",
        )


class NavigationRailCoversTheDeckTests(unittest.TestCase):
    """The rail is the only way to jump between sections, and it is hand-maintained.
    It was missing its last entry: the deck ends on "Where we go from here" and the
    rail stopped at Q&A, so the closing section had no dot and the Q&A dot stayed lit
    through it.

    Labels are not compared, for the same reason segment names are not -- the rail
    says "Q&A" and "Why this exists" where the slide map says "Questions you're about
    to ask" and "Why any of this exists". Where the sections *begin* is the one fact
    both files state."""

    def setUp(self):
        self.slides = deck_slides()
        self.rail = RAIL_NODE.findall(DECK.read_text())

    def test_every_rail_link_points_at_a_slide_that_exists(self):
        """A dangling anchor is silent: the click does nothing and the observer never
        lights the dot."""
        ids = {slide_id for slide_id, _heading in self.slides}
        dangling = [href for href in self.rail if href not in ids]

        self.assertEqual([], dangling, f"rail links to {dangling}, which no slide defines")

    def test_the_rail_has_a_node_per_section_and_no_others(self):
        position = {slide_id: index + 1 for index, (slide_id, _heading) in enumerate(self.slides)}
        linked = [position[href] for href in self.rail]

        self.assertEqual(
            section_start_slides(SCRIPT.read_text()),
            linked,
            "the rail's nodes and the slide map's sections disagree about where the "
            "deck's sections begin",
        )

    def test_the_rail_is_in_deck_order(self):
        position = {slide_id: index for index, (slide_id, _heading) in enumerate(self.slides)}
        linked = [position[href] for href in self.rail]

        self.assertEqual(sorted(linked), linked, "the rail's nodes are not in deck order")


class ProseSlideReferencesResolveTests(unittest.TestCase):
    def test_no_prose_reference_points_past_the_end_of_the_deck(self):
        """The failure that has already happened twice: a slide is added or cut and
        the numbered references in the segment notes and the cut list keep pointing
        where the slide used to be. Only the range is checkable here, but a reference
        past the end is unambiguously stale."""
        total = len(deck_headings())

        out_of_range = sorted(
            {
                int(number)
                for match in PROSE_SLIDE_REF.finditer(SCRIPT.read_text())
                for number in match.groups()
                if number is not None and not 1 <= int(number) <= total
            }
        )

        self.assertEqual(
            [],
            out_of_range,
            f"the script refers to slides {out_of_range} but the deck has {total}",
        )


if __name__ == "__main__":
    unittest.main()
