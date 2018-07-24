library jaguar_orm.generator.parser;

import 'package:source_gen/source_gen.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/dart/constant/value.dart';

import 'package:jaguar_orm_gen/src/common/common.dart';
import 'package:jaguar_orm_gen/src/model/model.dart';

/// Parses the `@GenBean()` into `WriterModel` so that `ModelModel` can be used
/// to generate the code by `Writer`.
class ParsedBean {
  /// Should connect relations?
  ///
  /// Set this false to avoid connecting relations. Since connecting relations
  /// is recursive, this avoids infinite recursion. This shall be set only for
  /// the `Bean` being generated.
  final bool doRelations;

  /// The [ClassElement] element of the `GenBean` spec.
  final ClassElement clazz;

  /// The model of the Bean
  DartType model;

  /// Constant reader used to read fields from the `GenBean`
  ConstantReader reader;

  /// Parsed fields are stored here while being parsed.
  ///
  /// This is part of the state of the parser.
  final fields = <String, Field>{};

  /// Parsed preloads are stored here while being parsed.
  ///
  /// This is part of the state of the parser.
  final preloads = <Preload>[];

  final primaries = <Field>[];

  final beanedAssociations = <DartType, BelongsToAssociation>{};

  final beanedForeignAssociations = <DartType, BeanedForeignAssociation>{};

  ParsedBean(this.clazz, {this.doRelations: true});

  WriterModel detect() {
    _getModel();

    _parseFields();

    // Collect [BelongsToAssociation] from [BelongsToForeign]
    for (Field f in fields.values) {
      if (f.foreign is! BelongsToForeign) continue;

      final BelongsToForeign foreign = f.foreign;
      final DartType bean = foreign.bean;
      BelongsToAssociation current = beanedAssociations[bean];

      final WriterModel info =
          new ParsedBean(bean.element, doRelations: false).detect();

      final Preload other = info.findHasXByAssociation(clazz.type);

      if (other == null) continue;

      if (current == null) {
        bool byHasMany = foreign.byHasMany;
        if (byHasMany != null) {
          if (byHasMany != other.hasMany) {
            throw new Exception('Mismatching association type!');
          }
        } else {
          byHasMany = other.hasMany;
        }
        current = new BelongsToAssociation(bean, [], [], other, byHasMany);
        beanedAssociations[bean] = current;
      } else if (current is BelongsToAssociation) {
        if (current.byHasMany != other.hasMany) {
          throw new Exception('Mismatching association type!');
        }
        if (current.belongsToMany != other is PreloadManyToMany) {
          throw new Exception('Mismatching association type!');
        }
      } else {
        throw new Exception('Table and bean associations mixed!');
      }
      beanedAssociations[bean].fields.add(f);
    }

    // Collect [BeanedForeignAssociation] from [BelongsToForeign]
    for (Field f in fields.values) {
      if (f.foreign is! BelongsToForeign) continue;

      final BelongsToForeign foreign = f.foreign;
      final DartType bean = foreign.bean;

      {
        final WriterModel info =
            new ParsedBean(bean.element, doRelations: false).detect();
        final Preload other = info.findHasXByAssociation(clazz.type);
        if (other != null) continue;
      }

      if (foreign.byHasMany == null)
        throw new Exception(
            'For un-associated foreign keys, "byHasMany" must be specified!');

      BeanedForeignAssociation current = beanedForeignAssociations[bean];

      if (current == null) {
        current = new BeanedForeignAssociation(bean, [], [], foreign.byHasMany);
        beanedForeignAssociations[bean] = current;
      } else if (current is BeanedForeignAssociation) {
        if (current.byHasMany != foreign.byHasMany) {
          throw new Exception('Mismatching association type!');
        }
      } else {
        throw new Exception('Table and bean associations mixed!');
      }
      beanedForeignAssociations[bean].fields.add(f);
    }

    // Collect [TabledForeignAssociation] from [TableForeign]
    for (Field f in fields.values) {
      if (f.foreign is! TableForeign) continue;

      throw new UnimplementedError('ForeignKey that is not beaned!');

      /* TODO
      final ForeignTabled foreign = f.foreign;
      final String association = foreign.association;
      FindByForeign current = findByForeign[association];

      if (current == null) {
        current = new FindByForeignTable(
            association, [], foreign.hasMany, foreign.table);
        findByForeign[association] = current;
      } else if (current is FindByForeignTable) {
        if (current.table != foreign.table) {
          throw new Exception('Mismatching table for association!');
        }
        if (current.isMany != foreign.hasMany) {
          throw new Exception('Mismatching ForeignKey association type!');
        }
      } else {
        throw new Exception('Table and bean associations mixed!');
      }
      findByForeign[association].fields.add(f);
      */
    }

    for (BelongsToAssociation m in beanedAssociations.values) {
      final WriterModel info =
          new ParsedBean(m.bean.element, doRelations: false).detect();

      for (Field f in m.fields) {
        Field ff = info.fieldByColName(f.foreign.refCol);

        if (ff == null)
          throw new Exception('Foreign key in foreign model not found!');

        m.foreignFields.add(ff);
      }
    }

    for (BeanedForeignAssociation m in beanedForeignAssociations.values) {
      final WriterModel info =
          new ParsedBean(m.bean.element, doRelations: false).detect();

      for (Field f in m.fields) {
        Field ff = info.fieldByColName(f.foreign.refCol);

        if (ff == null)
          throw new Exception('Foreign key in foreign model not found!');

        m.foreignFields.add(ff);
      }
    }

    final ret = new WriterModel(clazz.name, model.name, fields, primaries,
        beanedAssociations, beanedForeignAssociations, preloads);

    if (doRelations) {
      for (Preload p in preloads) {
        for (Field f in p.foreignFields) {
          Field ff = ret.fieldByColName(f.foreign.refCol);

          if (ff == null)
            throw new Exception('Foreign key in foreign model not found!');

          p.fields.add(ff);
        }
      }
    }

    return ret;
  }

  /// Parses and populates [model] and [reader]
  void _getModel() {
    if (!isBean.isAssignableFromType(clazz.type)) {
      throw new Exception("Beans must implement Bean interface!");
    }

    final InterfaceType interface = clazz.allSupertypes
        .firstWhere((InterfaceType i) => isBean.isExactlyType(i));

    model = interface.typeArguments.first;

    if (model.isDynamic) {
      throw new Exception("Don't support Model of type dynamic!");
    }

    reader = new ConstantReader(clazz.metadata
        .firstWhere((m) => isGenBean.isExactlyType(m.constantValue.type))
        .constantValue);
  }

  /// Parses and populates [fields]
  void _parseFields() {
    final ignores = new Set<String>();

    final ClassElement modelClass = model.element;

    final relations = new Set<String>();

    // Parse relations from GenBean::relations specification
    {
      final Map cols = reader.read('relations').mapValue;
      for (DartObject name in cols.keys) {
        final fieldName = name.toStringValue();
        final field = modelClass.getField(fieldName);

        if (field == null) throw Exception('Cannot find field $fieldName!');

        relations.add(fieldName);

        final DartObject spec = cols[name];
        parseRelation(clazz.type, field, spec);
      }
    }

    // Parse columns from GenBean::columns specification
    {
      final Map cols = reader.read('columns').mapValue;
      for (DartObject name in cols.keys) {
        final fieldName = name.toStringValue();

        if (relations.contains(fieldName))
          throw new Exception(
              'Cannot have both a column and relation: $fieldName!');

        final field = modelClass.getField(fieldName);

        if (field == null) throw new Exception('Cannot find field $fieldName!');

        final DartObject spec = cols[name];
        if (isIgnore.isExactlyType(spec.type)) {
          ignores.add(fieldName);
          continue;
        }

        final val = parseColumn(field, spec);

        fields[val.field] = val;
        if (val.primary) primaries.add(val);
      }
    }

    for (FieldElement field in modelClass.fields) {
      if (fields.containsKey(field.name)) continue;
      if (relations.contains(field.name)) continue;
      if (ignores.contains(field.name)) continue;

      //If IgnoreField is present, skip!
      {
        int ignore = field.metadata
            .map((ElementAnnotation annot) => annot.computeConstantValue())
            .where((DartObject inst) => isIgnore.isExactlyType(inst.type))
            .length;

        if (ignore != 0) {
          ignores.add(field.name);
          continue;
        }
      }

      if (field.isStatic) continue;

      final val = _makeField(field);

      if (val is Field) {
        fields[val.field] = val;
        if (val.primary) primaries.add(val);
      } else {
        if (!_relation(clazz.type, field)) {
          final vf = new Field(field.type.name, field.name, field.name);
          fields[vf.field] = vf;
        }
      }
    }
  }

  static Field _makeField(FieldElement f) {
    List<Field> fields = f.metadata
        .map((ElementAnnotation annot) => annot.computeConstantValue())
        .where((DartObject i) => isColumnBase.isAssignableFromType(i.type))
        .map((DartObject i) => parseColumn(f, i))
        .toList();

    if (fields.length > 1) {
      throw new Exception('Only one Column annotation is allowed on a Field!');
    }

    if (fields.length == 0) return null;

    return fields.first;
  }

  bool _relation(DartType curBean, FieldElement f) {
    DartObject rel;
    for (ElementAnnotation annot in f.metadata) {
      DartObject v = annot.computeConstantValue();
      if (!isRelation.isAssignableFromType(v.type)) continue;
      if (rel != null)
        throw new Exception(
            'Only one Relation annotation is allowed on a Field!');
      rel = v;
    }

    if (rel == null) return false;

    parseRelation(curBean, f, rel);

    return true;
  }

  void parseRelation(DartType curBean, FieldElement f, DartObject obj) {
    if (isHasOne.isExactlyType(obj.type) || isHasMany.isExactlyType(obj.type)) {
      final DartType bean = obj.getField('bean').toTypeValue();

      if (!isBean.isAssignableFromType(bean)) {
        throw new Exception("Non-bean type provided!");
      }

      BelongsToAssociation g;
      if (doRelations) {
        final WriterModel info =
            new ParsedBean(bean.element, doRelations: false).detect();
        g = info.belongTos[curBean];
        if (g == null || g is! BelongsToAssociation)
          throw new Exception('Association $bean not found! Field ${f.name}.');
      }

      final bool hasMany = isHasMany.isExactlyType(obj.type);

      preloads.add(new PreloadOneToX(bean, f.name, g?.fields, hasMany));
      return;
    } else if (isManyToMany.isExactlyType(obj.type)) {
      final DartType pivot = obj.getField('pivotBean').toTypeValue();
      final DartType target = obj.getField('targetBean').toTypeValue();

      if (!isBean.isAssignableFromType(pivot)) {
        throw new Exception("Non-bean type provided!");
      }

      if (!isBean.isAssignableFromType(target)) {
        throw new Exception("Non-bean type provided!");
      }

      BelongsToAssociation g;
      if (doRelations) {
        final WriterModel beanInfo =
            new ParsedBean(pivot.element, doRelations: false).detect();
        g = beanInfo.belongTos[curBean];
        if (g == null || g is! BelongsToAssociation) {
          throw new Exception('Association $curBean not found! Field ${f.name}.');
        }
        final WriterModel targetInfo =
            new ParsedBean(target.element, doRelations: false).detect();
        preloads.add(new PreloadManyToMany(
            pivot, target, f.name, targetInfo, beanInfo, g?.fields));
        return;
      }

      preloads
          .add(new PreloadManyToMany(pivot, target, f.name, null, null, null));
      return;
    }

    throw new Exception('Invalid Relation type!');
  }
}

Field parseColumn(FieldElement f, DartObject obj) {
  final String colName = obj.getField('col').toStringValue();
  final bool nullable = obj.getField('nullable').toBoolValue();
  final bool autoIncrement = obj.getField('autoIncrement').toBoolValue();
  final int length = obj.getField('length').toIntValue();
  if (isColumn.isExactlyType(obj.type)) {
    return new Field(f.type.name, f.name, colName,
        nullable: nullable, autoIncrement: autoIncrement, length: length);
  } else if (isPrimaryKey.isExactlyType(obj.type)) {
    return new Field(f.type.name, f.name, colName,
        nullable: nullable,
        primary: true,
        autoIncrement: autoIncrement,
        length: length);
  } else if (isForeignKey.isAssignableFromType(obj.type)) {
    final String table = obj.getField('table').toStringValue();
    final String refCol = obj.getField('refCol').toStringValue();

    Foreign fore = new TableForeign(table, refCol);

    return new Field(f.type.name, f.name, colName,
        nullable: nullable,
        foreign: fore,
        autoIncrement: autoIncrement,
        length: length);
  } else if (isBelongsTo.isAssignableFromType(obj.type)) {
    final DartType bean = obj.getField('bean').toTypeValue();
    final String refCol = obj.getField('refCol').toStringValue();
    final bool byHasMany = obj.getField('byHasMany').toBoolValue();
    final bool toMany = obj.getField('toMany').toBoolValue();

    if (!isBean.isAssignableFromType(bean)) {
      throw new Exception("Non-bean type provided!");
    }

    Foreign fore = new BelongsToForeign(bean, refCol, byHasMany, toMany);
    return new Field(f.type.name, f.name, colName,
        nullable: nullable,
        foreign: fore,
        autoIncrement: autoIncrement,
        length: length);
  }

  throw new FieldException(f.name, 'Invalid ColumnBase type!');
}
