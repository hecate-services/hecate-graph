//! CozoDB NIF for hecate-graph.
//!
//! Embeds CozoDB — a transactional, relational-graph-vector database that
//! uses Datalog for queries — as an Erlang NIF via Rustler.
//!
//! The NIF owns a single CozoDB instance backed by RocksDB on local disk.
//! All queries are Datalog strings, so the Erlang side never needs to
//! know the internal storage format.
//!
//! ## NIF functions
//!
//! - `open(Path)` — open or create a CozoDB instance at `Path`
//! - `run(Query, Params)` — run a Datalog query, return rows as a list of maps
//! - `run_script(Script)` — run a multi-statement Datalog script
//! - `close()` — close the database
//!
//! ## Fallback
//!
//! If the NIF is not loaded (no Rust toolchain at build time), the Erlang
//! wrapper module returns `{error, nif_not_loaded}`. There is no pure-Erlang
//! fallback for a graph database.

use rustler::{Atom, Binary, Encoder, Env, MapIterator, NifResult, ResourceArc, Term};
use std::sync::Mutex;

mod atoms {
    rustler::atoms! {
        ok,
        error,
        nif_not_loaded,
        rows,
        status,
        n,
        entity_id,
        link_id
    }
}

/// CozoDB instance wrapped in a Mutex for thread-safe access from NIFs.
struct CozoDb(Mutex<cozo::Db>);

impl Drop for CozoDb {
    fn drop(&mut self) {
        let _ = self.0.get_mut().map(|db| db.close());
    }
}

fn load(env: Env, _info: Term) -> bool {
    rustler::resource!(CozoDb, env);
    true
}

/// Open or create a CozoDB instance with RocksDB storage at the given path.
#[rustler::nif]
fn open(path: String) -> NifResult<Term> {
    let db = cozo::Db::open_rocksdb(&path, None)
        .map_err(|e| rustler::Error::Term(Box::new(format!("cozo open failed: {}", e))))?;
    let resource = ResourceArc::new(CozoDb(Mutex::new(db)));
    Ok((atoms::ok(), resource).encode(env()))
}

/// Run a single Datalog query with optional parameters.
///
/// `Params` is a map of variable name -> value bindings.
/// Returns `{ok, [{rows, [Map, ...]}, {status, Str}]}`.
#[rustler::nif]
fn run_query(env: Env, resource: ResourceArc<CozoDb>, query: String, params: Term) -> NifResult<Term> {
    let db = resource.0.lock().map_err(|_| {
        rustler::Error::Term(Box::new("cozo db mutex poisoned"))
    })?;

    let param_map = term_to_json(params)?;
    let json_str = serde_json::to_string(&param_map)
        .map_err(|e| rustler::Error::Term(Box::new(format!("json encode failed: {}", e))))?;

    let result = db.run_script(&query, if json_str == "null" { "" } else { &json_str })
        .map_err(|e| rustler::Error::Term(Box::new(format!("cozo query failed: {}", e))))?;

    let parsed: serde_json::Value = serde_json::from_str(&result)
        .map_err(|e| rustler::Error::Term(Box::new(format!("cozo response parse failed: {}", e))))?;

    let rows = json_to_term(env, &parsed);
    Ok((atoms::ok(), rows).encode(env))
}

/// Run a multi-statement Datalog script (no parameters).
#[rustler::nif]
fn run_script(env: Env, resource: ResourceArc<CozoDb>, script: String) -> NifResult<Term> {
    let db = resource.0.lock().map_err(|_| {
        rustler::Error::Term(Box::new("cozo db mutex poisoned"))
    })?;

    let result = db.run_script(&script, "")
        .map_err(|e| rustler::Error::Term(Box::new(format!("cozo script failed: {}", e))))?;

    let parsed: serde_json::Value = serde_json::from_str(&result)
        .map_err(|e| rustler::Error::Term(Box::new(format!("cozo response parse failed: {}", e))))?;

    let rows = json_to_term(env, &parsed);
    Ok((atoms::ok(), rows).encode(env))
}

/// Close the database.
#[rustler::nif]
fn close(_env: Env, resource: ResourceArc<CozoDb>) -> NifResult<Term> {
    let db = resource.0.lock().map_err(|_| {
        rustler::Error::Term(Box::new("cozo db mutex poisoned"))
    })?;
    db.close();
    Ok(atoms::ok().encode(_env))
}

/// Backup the database to a SQLite file.
#[rustler::nif]
fn backup(_env: Env, resource: ResourceArc<CozoDb>, path: String) -> NifResult<Term> {
    let db = resource.0.lock().map_err(|_| {
        rustler::Error::Term(Box::new("cozo db mutex poisoned"))
    })?;
    db.backup(&path)
        .map_err(|e| rustler::Error::Term(Box::new(format!("cozo backup failed: {}", e))))?;
    Ok(atoms::ok().encode(_env))
}

/// Restore the database from a SQLite file.
#[rustler::nif]
fn restore(_env: Env, resource: ResourceArc<CozoDb>, path: String) -> NifResult<Term> {
    let db = resource.0.lock().map_err(|_| {
        rustler::Error::Term(Box::new("cozo db mutex poisoned"))
    })?;
    db.restore(&path)
        .map_err(|e| rustler::Error::Term(Box::new(format!("cozo restore failed: {}", e))))?;
    Ok(atoms::ok().encode(_env))
}

// ---------------------------------------------------------------------------
// JSON <-> Erlang term conversion
// ---------------------------------------------------------------------------

fn term_to_json(term: Term) -> NifResult<serde_json::Value> {
    if term.is_atom() {
        let atom: Atom = term.decode()?;
        if atom == atoms::ok() { return Ok(serde_json::Value::Null); }
        return Ok(serde_json::Value::String(format!("{:?}", atom)));
    }
    if term.is_number() {
        if let Ok(i) = term.decode::<i64>() {
            return Ok(serde_json::Value::Number(i.into()));
        }
        if let Ok(f) = term.decode::<f64>() {
            if let Some(n) = serde_json::Number::from_f64(f) {
                return Ok(serde_json::Value::Number(n));
            }
        }
    }
    if term.is_binary() {
        let bin: Binary = term.decode()?;
        return Ok(serde_json::Value::String(
            String::from_utf8_lossy(bin.as_slice()).to_string()
        ));
    }
    if term.is_list() {
        let list: Vec<Term> = term.decode()?;
        let items: Result<Vec<serde_json::Value>, _> = list.iter()
            .map(term_to_json)
            .collect();
        return Ok(serde_json::Value::Array(items?));
    }
    if term.is_map() {
        let iter: MapIterator = term.decode()?;
        let mut map = serde_json::Map::new();
        for (k, v) in iter {
            let key = match term_to_json(k)? {
                serde_json::Value::String(s) => s,
                serde_json::Value::Number(n) => n.to_string(),
                _ => return Err(rustler::Error::Term(Box::new("map keys must be strings or numbers"))),
            };
            map.insert(key, term_to_json(v)?);
        }
        return Ok(serde_json::Value::Object(map));
    }
    Ok(serde_json::Value::Null)
}

fn json_to_term<'a>(env: Env<'a>, value: &serde_json::Value) -> Term<'a> {
    match value {
        serde_json::Value::Null => rustler::types::atom::nil().encode(env),
        serde_json::Value::Bool(b) => {
            if *b { rustler::types::atom::true_().encode(env) }
            else { rustler::types::atom::false_().encode(env) }
        }
        serde_json::Value::Number(n) => {
            if let Some(i) = n.as_i64() {
                i.encode(env)
            } else if let Some(f) = n.as_f64() {
                f.encode(env)
            } else {
                rustler::types::atom::nil().encode(env)
            }
        }
        serde_json::Value::String(s) => s.encode(env),
        serde_json::Value::Array(arr) => {
            let terms: Vec<Term> = arr.iter()
                .map(|v| json_to_term(env, v))
                .collect();
            terms.encode(env)
        }
        serde_json::Value::Object(obj) => {
            let pairs: Vec<(Term, Term)> = obj.iter()
                .map(|(k, v)| (k.encode(env), json_to_term(env, v)))
                .collect();
            Term::map_from_pairs(env, &pairs)
                .unwrap_or_else(|_| rustler::types::atom::nil().encode(env))
        }
    }
}

rustler::init!("hecate_graph_nif", [open, run_query, run_script, close, backup, restore], load = load);
