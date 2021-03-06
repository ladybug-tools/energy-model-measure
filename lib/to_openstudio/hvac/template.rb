# *******************************************************************************
# Honeybee OpenStudio Gem, Copyright (c) 2020, Alliance for Sustainable
# Energy, LLC, Ladybug Tools LLC and other contributors. All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
#
# (1) Redistributions of source code must retain the above copyright notice,
# this list of conditions and the following disclaimer.
#
# (2) Redistributions in binary form must reproduce the above copyright notice,
# this list of conditions and the following disclaimer in the documentation
# and/or other materials provided with the distribution.
#
# (3) Neither the name of the copyright holder nor the names of any contributors
# may be used to endorse or promote products derived from this software without
# specific prior written permission from the respective party.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDER(S) AND ANY CONTRIBUTORS
# "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
# THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
# ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER(S), ANY CONTRIBUTORS, THE
# UNITED STATES GOVERNMENT, OR THE UNITED STATES DEPARTMENT OF ENERGY, NOR ANY OF
# THEIR EMPLOYEES, BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
# EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT
# OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
# INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
# STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
# OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
# *******************************************************************************

require 'honeybee/hvac/template'

require 'to_openstudio/model_object'

module Honeybee
  class TemplateHVAC
    @@vintage_mapper = {
      DOE_Ref_Pre_1980: 'DOE Ref Pre-1980',
      DOE_Ref_1980_2004: 'DOE Ref 1980-2004',
      ASHRAE_2004: '90.1-2004',
      ASHRAE_2007: '90.1-2007',
      ASHRAE_2010: '90.1-2010',
      ASHRAE_2013: '90.1-2013'
    }

    def to_openstudio(openstudio_model, room_ids)

      # only load openstudio-standards when needed
      require 'openstudio-standards'
      require_relative 'Model.hvac'

      # get the defaults for the specific system type
      hvac_defaults = defaults(@hash[:type])

      # make the standard applier
      if @hash[:vintage]
        standard = Standard.build(@@vintage_mapper[@hash[:vintage].to_sym])
      else
        standard = Standard.build(@@vintage_mapper[hvac_defaults[:vintage][:default].to_sym])
      end

      # get the default equipment type
      if @hash[:equipment_type]
        equipment_type = @hash[:equipment_type]
      else
        equipment_type = hvac_defaults[:equipment_type][:default]
      end

      # get all of the thermal zones from the Model using the room identifiers
      zones = []
      room_ids.each do |room_id|
        zone_get = openstudio_model.getThermalZoneByName(room_id)
        unless zone_get.empty?
          os_thermal_zone = zone_get.get
          zones << os_thermal_zone
        end
      end

      # create the HVAC system and assign the display name to the air loop name if it exists
      os_hvac = openstudio_model.add_cbecs_hvac_system(standard, equipment_type, zones)
      os_air_loop = nil
      air_loops = openstudio_model.getAirLoopHVACs
      unless air_loops.length == $air_loop_count  # check if any new loops were added
        $air_loop_count = air_loops.length
        os_air_loop = air_loops[-1]
        loop_name = os_air_loop.name
        unless loop_name.empty?
          if @hash[:display_name]
            os_air_loop.setName(@hash[:display_name] + ' - ' + loop_name.get)
          end
        end
      end

      # assign the economizer type if there's an air loop and the economizer is specified
      if @hash[:economizer_type] && @hash[:economizer_type] != 'Inferred' && os_air_loop
        oasys = os_air_loop.airLoopHVACOutdoorAirSystem
        unless oasys.empty?
            os_oasys = oasys.get
            oactrl = os_oasys.getControllerOutdoorAir
            oactrl.setEconomizerControlType(@hash[:economizer_type])
        end
      end

      # set the sensible heat recovery if there's an air loop and the heat recovery is specified
      if @hash[:sensible_heat_recovery] && @hash[:sensible_heat_recovery] != {:type => 'Autosize'} && os_air_loop
        erv = get_existing_erv(os_air_loop)
        unless erv
          erv = create_erv(openstudio_model, os_air_loop)
        end
        eff_at_max = @hash[:sensible_heat_recovery] * (0.76 / 0.81)  # taken from OpenStudio defaults
        erv.setSensibleEffectivenessat100CoolingAirFlow(eff_at_max)
        erv.setSensibleEffectivenessat100HeatingAirFlow(eff_at_max)
        erv.setSensibleEffectivenessat75CoolingAirFlow(@hash[:sensible_heat_recovery])
        erv.setSensibleEffectivenessat75HeatingAirFlow(@hash[:sensible_heat_recovery])
      end

      # set the latent heat recovery if there's an air loop and the heat recovery is specified
      if @hash[:latent_heat_recovery] && @hash[:latent_heat_recovery] != {:type => 'Autosize'} && os_air_loop
        erv = get_existing_erv(os_air_loop)
        unless erv
          erv = create_erv(openstudio_model, os_air_loop)
        end
        eff_at_max = @hash[:latent_heat_recovery] * (0.68 / 0.73)  # taken from OpenStudio defaults
        erv.setLatentEffectivenessat100CoolingAirFlow(eff_at_max)
        erv.setLatentEffectivenessat100HeatingAirFlow(eff_at_max)
        erv.setLatentEffectivenessat75CoolingAirFlow(@hash[:latent_heat_recovery])
        erv.setLatentEffectivenessat75HeatingAirFlow(@hash[:latent_heat_recovery])
      end

      # set all plants to non-coincident sizing to avoid simualtion control on design days
      openstudio_model.getPlantLoops.each do |loop|
        sizing = loop.sizingPlant
        sizing.setSizingOption('NonCoincident')
      end

      os_hvac
    end

  private

    def get_existing_erv(os_air_loop)
      # get an existing heat ecovery unit from an air loop; will be nil if there is none
      os_air_loop.oaComponents.each do |supply_component|
        if not supply_component.to_HeatExchangerAirToAirSensibleAndLatent.empty?
          erv = supply_component.to_HeatExchangerAirToAirSensibleAndLatent.get
          return erv
        end
      end
      nil
    end

    def create_erv(model, os_air_loop)
      # create a heat recovery unit with default zero efficiencies
      heat_ex = OpenStudio::Model::HeatExchangerAirToAirSensibleAndLatent.new(model)
      heat_ex.setEconomizerLockout(false)
      heat_ex.setName(@hash[:identifier] + '_Heat Recovery Unit')
      heat_ex.setSensibleEffectivenessat100CoolingAirFlow(0)
      heat_ex.setSensibleEffectivenessat100HeatingAirFlow(0)
      heat_ex.setSensibleEffectivenessat75CoolingAirFlow(0)
      heat_ex.setSensibleEffectivenessat75HeatingAirFlow(0)
      heat_ex.setLatentEffectivenessat100CoolingAirFlow(0)
      heat_ex.setLatentEffectivenessat100HeatingAirFlow(0)
      heat_ex.setLatentEffectivenessat75CoolingAirFlow(0)
      heat_ex.setLatentEffectivenessat75HeatingAirFlow(0)

      # add the heat exchanger to the air loop
      outdoor_node = os_air_loop.reliefAirNode
      unless outdoor_node.empty?
        os_outdoor_node = outdoor_node.get
        heat_ex.addToNode(os_outdoor_node)
      end
      heat_ex
    end

  end #TemplateHVAC
end #Honeybee
