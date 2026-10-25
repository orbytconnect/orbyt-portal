-- Orbyt portal: update 7
-- Lets agents and Orbyt set a custom order of work on a project. Safe to run more than once.
alter table public.projects add column if not exists work_order jsonb;
