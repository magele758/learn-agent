/** Local reading records. One document file, one annotation list. No scores. */

export interface ReadingPage {
  /** 1-based page number. */
  page: number;
  text: string;
}

export interface ReadingDocument {
  id: string;
  title: string;
  sourcePath: string;
  importedAt: string;
  pages: ReadingPage[];
}

export interface AnnotationTurn {
  id: string;
  question: string;
  answer: string;
  createdAt: string;
}

/** A highlight on one page, plus the note and any AI replies about that quote. */
export interface Annotation {
  id: string;
  documentId: string;
  page: number;
  quote: string;
  note: string;
  createdAt: string;
  turns: AnnotationTurn[];
}
