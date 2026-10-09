import Foundation
@testable import NotesModels

/// The evaluation set for NOVA's notebook answers (mandate §75–76): three
/// notebooks written the way a student's recognised handwriting reads, and
/// questions with the pages that answer them, or none when the notes don't.
///
/// Offline, it scores page retrieval (`NovaGrounding.relevant`) on every test
/// run. Live (`NovaLiveEvalTests`, opt-in), it scores the real model: does an
/// answer cite a right page, does a question the notes can't answer say so,
/// and does any answer cite a page that doesn't exist.
enum NovaEvalSet {
    struct Notebook {
        let title: String
        let pages: [NovaGrounding.Page]
    }

    struct Question {
        let notebook: Int
        let text: String
        /// Pages that answer it. Empty: the notes don't, and the answer should
        /// open "Not in your notes:".
        let answeredBy: Set<Int>
        /// How the question finds its page: by the words it shares, by
        /// paraphrase (shares few words), or by naming the page.
        let style: Style
    }

    enum Style: String { case lexical, paraphrase, named, outside }

    static let notebooks: [Notebook] = [
        Notebook(title: "Biology — Cells", pages: [
            .init(number: 0, text: "Biology\nYear 11 — Mr Okafor"),
            .init(number: 1, text: """
                Cell theory
                1. all living things are made of cells
                2. the cell is the basic unit of life
                3. cells come from pre-existing cells (Virchow 1855)
                prokaryotes: no nucleus, e.g. bacteria. eukaryotes: nucleus + membrane-bound organelles
                """),
            .init(number: 2, text: """
                Organelles
                nucleus - holds DNA, controls the cell
                mitochondria - aerobic respiration, makes ATP ("powerhouse")
                ribosomes - protein synthesis, on rough ER or free
                chloroplasts - photosynthesis, plant cells only
                cell wall - cellulose, plants only, keeps shape
                """),
            .init(number: 3, text: """
                Transport across membranes
                diffusion: high to low concentration, passive, no energy
                osmosis: diffusion of WATER through a partially permeable membrane
                from dilute to concentrated solution
                active transport: against the gradient, needs ATP, carrier proteins
                e.g. root hair cells taking up mineral ions
                """),
            .init(number: 4, text: """
                Mitosis
                interphase: DNA replicates, cell grows
                prophase -> metaphase (chromosomes line up at equator) -> anaphase
                (chromatids pulled apart) -> telophase -> cytokinesis
                result: 2 genetically identical diploid cells. used for growth + repair
                """),
            .init(number: 5, text: """
                Enzymes
                biological catalysts, proteins. lock and key: substrate fits active site
                denature above ~40°C: active site changes shape, substrate no longer fits
                optimum pH: pepsin ~2 (stomach), amylase ~7
                """),
            .init(number: 6, text: """
                Required practical: osmosis in potato
                cut cylinders, weigh, place in sucrose 0 - 1.0 M for 24h, reweigh
                % change in mass vs concentration. where line crosses 0 = concentration of cell sap
                errors: blotting dry inconsistently, evaporation
                """)
        ]),
        Notebook(title: "History — Cold War", pages: [
            .init(number: 1, text: """
                Origins of the Cold War
                Yalta Feb 1945: Big Three (Churchill Roosevelt Stalin), Germany divided into 4 zones
                Potsdam Jul 1945: Truman + Attlee, tension over Poland, atomic bomb
                ideology: capitalism vs communism
                """),
            .init(number: 2, text: """
                Truman Doctrine 1947 - containment, aid to Greece + Turkey
                Marshall Plan - $13bn to rebuild Western Europe, Stalin called it dollar imperialism
                Cominform + Comecon as Soviet response
                """),
            .init(number: 3, text: """
                Berlin Blockade 1948-49
                Stalin cut road + rail links to West Berlin
                Berlin Airlift: 2.3m tons of supplies flown in over 11 months
                outcome: blockade lifted May 1949, NATO formed April 1949
                """),
            .init(number: 4, text: """
                Cuban Missile Crisis Oct 1962
                U2 spy planes photograph missile sites, 13 days
                Kennedy: naval quarantine. Khrushchev removes missiles, US secretly removes Jupiter missiles from Turkey
                led to hotline + Partial Test Ban Treaty 1963
                """),
            .init(number: 5, text: """
                Berlin Wall built Aug 1961 to stop the brain drain to the West
                Kennedy "Ich bin ein Berliner" 1963
                Wall falls 9 Nov 1989, Germany reunified 1990
                """)
        ]),
        Notebook(title: "Physics — Electricity", pages: [
            .init(number: 1, text: """
                Current, charge, potential difference
                Q = I t   (charge = current x time, coulombs)
                V = E / Q  potential difference in volts = energy per unit charge
                ammeter in series, voltmeter in parallel
                """),
            .init(number: 2, text: """
                Resistance
                V = I R (Ohm's law, for an ohmic conductor at constant temperature)
                filament lamp: resistance increases as it heats up, curved I-V graph
                diode: current flows one way only
                """),
            .init(number: 3, text: """
                Series and parallel
                series: same current everywhere, R total = R1 + R2
                parallel: same pd across each branch, total R less than smallest resistor
                """),
            .init(number: 4, text: """
                Power and energy
                P = I V = I² R
                E = P t (joules), kWh for bills: 1 kWh = 3.6 MJ
                National Grid: step-up transformers raise pd to reduce current and losses
                """),
            .init(number: 5, text: """
                Static electricity
                rubbing transfers electrons, insulators become charged
                like charges repel, opposite attract. sparks when pd large enough
                """)
        ])
    ]

    static let questions: [Question] = [
        // Biology
        .init(notebook: 0, text: "What does osmosis mean?", answeredBy: [3, 6], style: .lexical),
        .init(notebook: 0, text: "Which organelle makes ATP?", answeredBy: [2], style: .lexical),
        .init(notebook: 0, text: "What happens to enzymes when they get too hot?", answeredBy: [5], style: .lexical),
        .init(notebook: 0, text: "List the stages of mitosis", answeredBy: [4], style: .lexical),
        .init(notebook: 0, text: "How did we find the concentration of cell sap in the potato practical?",
              answeredBy: [6], style: .lexical),
        .init(notebook: 0, text: "Who said cells come from other cells?", answeredBy: [1], style: .lexical),
        .init(notebook: 0, text: "How do plants get minerals from soil against the gradient?", answeredBy: [3], style: .paraphrase),
        .init(notebook: 0, text: "What's the optimum pH for pepsin?", answeredBy: [5], style: .lexical),
        .init(notebook: 0, text: "Explain page 2", answeredBy: [2], style: .named),
        .init(notebook: 0, text: "Summarise pages 4-5", answeredBy: [4, 5], style: .named),
        .init(notebook: 0, text: "What is meiosis used for?", answeredBy: [], style: .outside),
        .init(notebook: 0, text: "How does the kidney filter blood?", answeredBy: [], style: .outside),
        // History
        .init(notebook: 1, text: "What was the Marshall Plan?", answeredBy: [2], style: .lexical),
        .init(notebook: 1, text: "How long did the Berlin Airlift last?", answeredBy: [3], style: .lexical),
        .init(notebook: 1, text: "Why was the Berlin Wall built?", answeredBy: [5], style: .lexical),
        .init(notebook: 1, text: "What did Kennedy do when the missiles were found in Cuba?", answeredBy: [4], style: .lexical),
        .init(notebook: 1, text: "Who met at Yalta?", answeredBy: [1], style: .lexical),
        .init(notebook: 1, text: "What was the US policy of containment?", answeredBy: [2], style: .lexical),
        .init(notebook: 1, text: "When did Germany become one country again?", answeredBy: [5], style: .paraphrase),
        .init(notebook: 1, text: "What's on page 3?", answeredBy: [3], style: .named),
        .init(notebook: 1, text: "What caused the Korean War?", answeredBy: [], style: .outside),
        .init(notebook: 1, text: "Who was Mikhail Gorbachev?", answeredBy: [], style: .outside),
        // Physics
        .init(notebook: 2, text: "What is Ohm's law?", answeredBy: [2], style: .lexical),
        .init(notebook: 2, text: "How do you connect a voltmeter?", answeredBy: [1], style: .lexical),
        .init(notebook: 2, text: "Why does the National Grid use transformers?", answeredBy: [4], style: .lexical),
        .init(notebook: 2, text: "How many joules in a kilowatt hour?", answeredBy: [4], style: .lexical),
        .init(notebook: 2, text: "What is the total resistance of resistors in series?", answeredBy: [3], style: .lexical),
        .init(notebook: 2, text: "Why do balloons stick to a wall after rubbing them on hair?", answeredBy: [5], style: .paraphrase),
        .init(notebook: 2, text: "Go through p. 1", answeredBy: [1], style: .named),
        .init(notebook: 2, text: "How does a nuclear reactor work?", answeredBy: [], style: .outside)
    ]
}
