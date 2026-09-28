using System;
using System.Collections.Generic;
using Godot;

/// <summary>
/// The mountain features of one pack tile (or of a chunk frame), summed in a
/// single call per sample — MountainRelief.offset in C#. Built once (Add*),
/// read-only afterwards, shared by the chunk workers.
/// </summary>
public partial class MountainSetNative : RefCounted
{
    private readonly List<MountainZoneNative> _zones = new();
    private readonly List<MountainRidgeNative> _ridges = new();
    /// <summary>Volcanoes (VolcanoRelief), summed AFTER the zones and the ridges —
    /// the order MountainRelief keeps too. They need no lon/lat.</summary>
    private readonly List<MountainVolcanoNative> _volcanoes = new();
    private bool _needLonLat;

    public void AddZone(GodotObject zone)
    {
        var z = zone as MountainZoneNative;
        if (z == null) return;
        _zones.Add(z);
        if (!z.IsFull()) _needLonLat = true;
    }

    public void AddRidge(GodotObject ridge)
    {
        var r = ridge as MountainRidgeNative;
        if (r == null) return;
        _ridges.Add(r);
        _needLonLat = true;
    }

    public void AddVolcano(GodotObject volcano)
    {
        var v = volcano as MountainVolcanoNative;
        if (v == null) return;
        _volcanoes.Add(v);
    }

    public bool IsEmpty() => _zones.Count == 0 && _ridges.Count == 0 && _volcanoes.Count == 0;
    public int ZoneCount() => _zones.Count;
    public int RidgeCount() => _ridges.Count;
    public int VolcanoCount() => _volcanoes.Count;

    /// <summary>Total offset (m) at dir for a grid of pitch effSpacing (> 0).</summary>
    public double Offset(Vector3 dir, double radius, double effSpacing)
    {
        double dx = dir.X, dy = dir.Y, dz = dir.Z;
        double lon = double.NaN, lat = double.NaN;
        if (_needLonLat)
            MountainNoiseCore.ToLonLat(dx, dy, dz, out lon, out lat);
        double total = 0.0;
        for (int i = 0; i < _zones.Count; i++)
            total += _zones[i].OffsetD(dx, dy, dz, radius, effSpacing, lon, lat);
        for (int i = 0; i < _ridges.Count; i++)
            total += _ridges[i].HeightD(dx, dy, dz, radius, effSpacing, lon, lat);
        for (int i = 0; i < _volcanoes.Count; i++)
            total += _volcanoes[i].OffsetD(dx, dy, dz, radius, effSpacing);
        return total;
    }

    /// <summary>MountainRelief.core: how deep inside a massif dir is, for the
    /// rock impurity fields — features add, LOD-independent.</summary>
    public double Core(Vector3 dir, double radius)
    {
        double dx = dir.X, dy = dir.Y, dz = dir.Z;
        double lon = double.NaN, lat = double.NaN;
        if (_needLonLat)
            MountainNoiseCore.ToLonLat(dx, dy, dz, out lon, out lat);
        double total = 0.0;
        for (int i = 0; i < _zones.Count; i++)
            total += _zones[i].CoreD(dx, dy, dz, radius, lon, lat);
        for (int i = 0; i < _ridges.Count; i++)
            total += _ridges[i].CoreD(dx, dy, dz, radius, lon, lat);
        for (int i = 0; i < _volcanoes.Count; i++)
            total += _volcanoes[i].CoreD(dx, dy, dz, radius);
        return total;
    }

    /// <summary>MountainRelief.mask: how much dir belongs to a mountain feature —
    /// a fadeM ramp inside the outlines / from the ridge feet, in [0, 1].</summary>
    public double Mask(Vector3 dir, double radius, double fadeM)
    {
        double dx = dir.X, dy = dir.Y, dz = dir.Z;
        double lon = double.NaN, lat = double.NaN;
        if (_needLonLat)
            MountainNoiseCore.ToLonLat(dx, dy, dz, out lon, out lat);
        double m = 0.0;
        for (int i = 0; i < _zones.Count; i++)
        {
            m = Math.Max(m, _zones[i].MaskD(dx, dy, dz, radius, lon, lat, fadeM));
            if (m >= 1.0) return 1.0;
        }
        for (int i = 0; i < _ridges.Count; i++)
            m = Math.Max(m, _ridges[i].MaskD(dx, dy, dz, radius, lon, lat, fadeM));
        for (int i = 0; i < _volcanoes.Count; i++)
            m = Math.Max(m, _volcanoes[i].MaskD(dx, dy, dz, radius, fadeM));
        return MountainNoiseCore.Clamp(m, 0.0, 1.0);
    }
}
